#!/usr/bin/env python3
"""Full evidence stays in this attempt; only immutable same-run scope may carry."""
import json
import os
import subprocess
import sys
import time

NAMES = {'scope': 'CI repository checks and PR scope',
         'full': 'Full CI (CLI, probes and serial XCTest)',
         'version': 'PR-wide version-only exemption (no XCTest)',
         'smoke': 'Pre-Liquid-Glass artifact smoke'}
WAITING = {'queued', 'in_progress', 'waiting', 'pending', 'requested'}


def event_kind(event):
    if event.get('action') != 'edited':
        return 'validation'
    changes = event.get('changes', {})
    if 'base' in changes:
        return 'retarget'
    if changes and set(changes) <= {'title', 'body'}:
        return 'metadata'
    return 'revalidate'


def pr_error(event_pr, live_pr):
    if not live_pr or live_pr.get('state') != 'open' or live_pr.get('draft') or event_pr.get('draft'):
        return 'Draft/closed PR has no merge credential'
    for ref, field in (('head', 'sha'), ('base', 'sha'), ('base', 'ref')):
        expected = event_pr.get(ref, {}).get(field)
        if not expected or live_pr.get(ref, {}).get(field) != expected:
            return f'PR {ref}.{field} missing/changed; fresh validation required'
    return None


def verdict(event, event_pr, live_pr, results, version_only):
    if event == 'pull_request':
        error = pr_error(event_pr, live_pr)
        if error:
            return False, error
    if results['scope'] != 'success':
        return False, 'Repository/scope checks did not succeed'
    if version_only:
        return results['version'] == 'success', 'PR-wide version-only exemption; XCTest NOT executed'
    return results['full'] == 'success', ('Full CI for event head/base' if event == 'pull_request'
                                        else 'Manual Full (no PR merge credential)')


def api(path, timeout=15):
    return json.loads(subprocess.check_output(['gh', 'api', path], text=True, timeout=timeout))


def job_state(job):
    return (job.get('conclusion') or job['status']) if job else 'missing'


def scope_from_history(jobs, run_id, head_sha, attempt):
    candidates = [j for j in jobs if j['name'] == NAMES['scope'] and j.get('run_attempt', attempt) < attempt]
    if not candidates:
        return None
    # Never fall back past a later failed/cancelled/skipped scope execution.
    latest = max(candidates, key=lambda j: (j['run_attempt'], j['id']))
    if (str(latest.get('run_id')) == run_id and latest.get('head_sha') == head_sha
            and latest['run_attempt'] >= 1 and latest.get('conclusion') == 'success'):
        same_execution = [j for j in candidates if str(j.get('run_id')) == run_id
                          and j.get('head_sha') == head_sha and j.get('conclusion') == 'success'
                          and j.get('started_at') == latest.get('started_at')
                          and j.get('completed_at') == latest.get('completed_at')]
        return min(same_execution, key=lambda j: (j['run_attempt'], j['id']))
    return None



def fresh_execution(job, since):
    # GitHub can clone a successful dependency into a new attempt/job ID while
    # retaining its old execution timestamps. run_attempt alone is not proof.
    if job_state(job) in WAITING:
        return True
    return bool(job.get('started_at') and job.get('completed_at')
                and job['started_at'] >= since and job['completed_at'] >= since)


def wait_for_evidence(event, event_name):
    repo = os.environ['GITHUB_REPOSITORY']
    run_id = os.environ['GITHUB_RUN_ID']
    attempt = int(os.environ['GITHUB_RUN_ATTEMPT'])
    pr = event.get('pull_request')
    head = pr['head']['sha'] if pr else os.environ['GITHUB_SHA']
    kind = event_kind(event)
    if kind == 'metadata' and event_name == 'pull_request':
        return False, 'Metadata edit only; NO merge credential', {'event': kind}
    version_only = False
    if pr and kind not in ('retarget', 'revalidate'):
        version_only = subprocess.check_output([
            'bash', '.github/scripts/classify-version-only-diff.sh', pr['base']['sha'], head],
            text=True, timeout=15).strip() == 'version-only'
    run_path = f'repos/{repo}/actions/runs/{run_id}'
    jobs_path = f'{run_path}/attempts/{attempt}/jobs?per_page=100'
    attempt_info = api(f'{run_path}/attempts/{attempt}', timeout=15)
    if (str(attempt_info.get('id')) != run_id or attempt_info.get('head_sha') != head
            or attempt_info.get('run_attempt') != attempt or not attempt_info.get('run_started_at')):
        return False, 'Attempt identity missing/mismatched', {}
    since = attempt_info['run_started_at']
    history_scope = None
    history_loaded = False
    missing_since = {}
    deadline = time.monotonic() + 23 * 60

    def request(path):
        remaining = min([deadline] + [t + 60 for t in missing_since.values()]) - time.monotonic()
        if remaining <= 0:
            raise TimeoutError('Evidence deadline reached; use Re-run all jobs')
        return api(path, timeout=min(15, remaining))

    while True:
        expired = [key for key, start in missing_since.items() if time.monotonic() - start >= 60]
        if expired:
            return False, f'Missing current-attempt jobs: {expired}; use Re-run all jobs', results
        try:
            live = request(f'repos/{repo}/pulls/{pr["number"]}') if pr else None
            if pr and (error := pr_error(pr, live)):
                return False, error, {}
            jobs = request(jobs_path)['jobs']
            current = {key: next((j for j in jobs if j['name'] == name and
                                  j.get('run_attempt') == attempt and str(j.get('run_id')) == run_id
                                  and j.get('head_sha') == head and fresh_execution(j, since)), None) for key, name in NAMES.items()}
            if not current['scope'] and attempt > 1 and not history_loaded:
                run = request(run_path)
                if str(run['id']) != run_id or run['head_sha'] != head:
                    return False, 'Run identity mismatch; no reusable scope', {}
                history = []
                page = 1
                while True:
                    data = request(f'{run_path}/jobs?filter=all&per_page=100&page={page}')
                    history.extend(data['jobs'])
                    if len(history) >= data['total_count']:
                        break
                    if not data['jobs']:
                        return False, 'Incomplete history response; no reusable scope', {}
                    page += 1
                history_scope = scope_from_history(history, run_id, head, attempt)
                history_loaded = True
            selected = dict(current)
            selected['scope'] = current['scope'] or history_scope
            results = {key: job_state(j) for key, j in selected.items()}
            results['evidence'] = {key: {'job_id': j['id'], 'attempt': j['run_attempt']}
                                   for key, j in selected.items() if j}
            results['scope_reused'] = bool(not current['scope'] and history_scope)
            lane = 'version' if version_only else 'full'
            required = ['scope']
            if results['scope'] == 'success':
                required.append(lane)
                if lane == 'full' and results['full'] == 'success':
                    required.append('smoke')
            # Missing downstream jobs get a grace period only after prerequisites succeed.
            absent = {key for key in required if results[key] == 'missing'}
            missing_since = {key: missing_since.get(key, time.monotonic()) for key in absent}
            expired = [key for key, start in missing_since.items() if time.monotonic() - start >= 60]
            if expired:
                return False, f'Missing current-attempt jobs: {expired}; use Re-run all jobs', results
            if results['scope'] not in WAITING | {'missing', 'success'}:
                return False, 'Repository/scope checks did not succeed', results
            if results['scope'] == 'success' and results[lane] not in WAITING | {'missing'}:
                ok, reason = verdict(event_name, pr, live, results, version_only)
                if not ok or lane == 'version':
                    return ok, reason, results
                if results['smoke'] not in WAITING | {'missing'}:
                    if results['smoke'] not in ('success', 'failure'):
                        return False, 'Smoke cancelled/skipped; incomplete run (failure remains advisory)', results
                    return ok, reason, results
            if time.monotonic() >= deadline:
                return False, 'Timed out waiting for running jobs; no Full credential', results
            next_deadline = min([deadline] + [t + 60 for t in missing_since.values()])
            time.sleep(min(15, max(0, next_deadline - time.monotonic())))
        except (subprocess.CalledProcessError, json.JSONDecodeError) as exc:
            return False, f'Evidence API failed: {exc}', locals().get('results', {})
        except (subprocess.TimeoutExpired, TimeoutError) as exc:
            return False, f'Evidence request timed out: {exc}; use Re-run all jobs', locals().get('results', {})


if __name__ == '__main__':
    event = json.load(open(os.environ['GITHUB_EVENT_PATH']))
    ok, reason, results = wait_for_evidence(event, os.environ['GITHUB_EVENT_NAME'])
    summary = f"{'PASS' if ok else 'FAIL'}: {reason}\nEvent head: {event.get('pull_request', {}).get('head', {}).get('sha', os.environ['GITHUB_SHA'])}\nBase: {event.get('pull_request', {}).get('base', {}).get('ref')} / {event.get('pull_request', {}).get('base', {}).get('sha')}\nCheckout/merge SHA: {os.environ['GITHUB_SHA']}\nResults: {results}\n"
    print(summary)
    with open(os.environ['GITHUB_STEP_SUMMARY'], 'a') as out:
        out.write(summary)
    sys.exit(0 if ok else 1)
