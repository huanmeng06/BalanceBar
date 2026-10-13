#!/usr/bin/env python3
"""Confirm Ready metadata edits from the most recent authentic Full gate."""
import json
import os
import subprocess
import sys
import time

NAMES = {'scope': 'CI repository checks and PR scope',
         'full': 'Full CI (CLI, probes and serial XCTest)',
         'version': 'PR-wide version-only exemption (no XCTest)',
         'smoke': 'Pre-Liquid-Glass artifact smoke'}


def api(path):
    return json.loads(subprocess.check_output(['gh', 'api', path], text=True, timeout=20))


def pr_error(event_pr, live):
    if not live or live.get('state') != 'open' or live.get('draft') or event_pr.get('draft'):
        return 'PR is Draft/closed; no metadata merge credential'
    for ref, field in (('head', 'sha'), ('base', 'sha'), ('base', 'ref')):
        expected = event_pr.get(ref, {}).get(field)
        if not expected or live.get(ref, {}).get(field) != expected:
            return f'PR {ref}.{field} changed; require fresh validation'
    return None


def metadata_log_matches(log, pr, merge_sha):
    # Run.pull_requests can project current refs for historical runs; use the
    # identity printed by the actual successful validation gate execution.
    lines = [line.split('Z ', 1)[-1].strip() for line in log.splitlines()]
    identity = ('Event head: ' + pr['head']['sha'],
                'Base: ' + pr['base']['ref'] + ' / ' + pr['base']['sha'],
                'Checkout/merge SHA: ' + merge_sha)
    return (all(item in lines for item in identity)
            and any(line.startswith('PASS: Full CI ') or
                    line.startswith('PASS: PR-wide version-only exemption')
                    for line in lines))


def metadata_source(runs, jobs_by_run, current_run_id, workflow_id, pr_number, head):
    candidates = sorted((r for r in runs
                         if r.get('id') != current_run_id
                         and r.get('workflow_id') == workflow_id
                         and r.get('event') == 'pull_request'
                         and r.get('head_sha') == head
                         and any(p.get('number') == pr_number for p in r.get('pull_requests', []))),
                        key=lambda r: r['id'], reverse=True)
    for run in candidates:
        jobs = jobs_by_run(run['id'])
        names = {j['name']: j for j in jobs}
        if not jobs:
            # Actions can publish a new run before creating any jobs. It is
            # still the newest validation and must hide older green runs.
            return run, jobs, 'Latest validation jobs are not yet visible'
        if 'Draft merge gate inactive (not required)' in names:
            return run, jobs, 'Draft validation is newer than Full'
        if names.get(NAMES['scope'], {}).get('conclusion') == 'skipped':
            # Only a completed metadata confirmation can be ignored. During
            # job creation a partial list cannot prove this is metadata-only.
            if (run.get('status') == 'completed'
                    and 'PR merge gate' in names
                    and all(names.get(NAMES[key], {}).get('conclusion') == 'skipped'
                            for key in ('full', 'version', 'smoke'))):
                continue
            return run, jobs, 'Latest validation jobs are not yet visible'
        if 'PR merge gate' in names or NAMES['scope'] in names:
            return run, jobs, None
        # Empty and partially published job lists have the same safety rule:
        # an unclassified newer run must never expose an older green result.
        return run, jobs, 'Latest validation jobs are not yet visible'
    return None, None, 'No prior Ready validation for this PR and head'


def metadata_gate(event):
    changes = event.get('changes') or {}
    if event.get('action') != 'edited' or not changes or set(changes) - {'title', 'body'}:
        return False, 'Not a strictly metadata-only PR edit; require Full CI', {}
    repo = os.environ['GITHUB_REPOSITORY']
    current_id = int(os.environ['GITHUB_RUN_ID'])
    pr = event['pull_request']
    pr_num, head = pr['number'], pr['head']['sha']
    current_run = api(f'repos/{repo}/actions/runs/{current_id}')
    if (current_run.get('event') != 'pull_request' or current_run.get('head_sha') != head
            or not current_run.get('workflow_id')):
        return False, 'Metadata run identity mismatch', {}
    deadline = time.monotonic() + 23 * 60
    missing_since = None

    def runs_for_head():
        all_runs = []
        for page in range(1, 11):
            data = api(f'repos/{repo}/actions/runs?event=pull_request&head_sha={head}&per_page=100&page={page}')
            all_runs.extend(data['workflow_runs'])
            if len(all_runs) >= data['total_count']:
                return all_runs
        raise ValueError('Too many runs to validate metadata safely')

    def jobs_by_run(run_id):
        data = api(f'repos/{repo}/actions/runs/{run_id}/jobs?per_page=100')
        if data.get('total_count', 0) > len(data.get('jobs', [])):
            raise ValueError('Incomplete validation jobs')
        return data['jobs']

    while time.monotonic() < deadline:
        try:
            live = api(f'repos/{repo}/pulls/{pr_num}')
            if error := pr_error(pr, live):
                return False, error, {}
            merge_sha = live.get('merge_commit_sha')
            if not merge_sha:
                return False, 'PR test-merge commit unavailable', {}
            source, jobs, error = metadata_source(runs_for_head(), jobs_by_run, current_id,
                                                  current_run['workflow_id'], pr_num, head)
            if error:
                if source and error != 'Latest validation jobs are not yet visible':
                    return False, error, {}
                if source and source['status'] != 'completed':
                    missing_since = None
                else:
                    if missing_since is None:
                        missing_since = time.monotonic()
                    if time.monotonic() - missing_since >= 60:
                        return False, error + '; run Ready Full CI', {}
            elif source['status'] != 'completed':
                missing_since = None
            else:
                if source.get('conclusion') != 'success':
                    return False, 'Latest Ready validation failed/cancelled', {'run_id': source['id']}
                names = {j['name']: j for j in jobs}
                gate = names.get('PR merge gate')
                if not gate or gate.get('conclusion') != 'success':
                    return False, 'Latest Ready gate not successful', {'run_id': source['id']}
                full = names.get(NAMES['full'], {}).get('conclusion') == 'success'
                version = names.get(NAMES['version'], {}).get('conclusion') == 'success'
                smoke = names.get(NAMES['smoke'], {}).get('conclusion') in ('success', 'failure')
                if not ((full and smoke) or version):
                    return False, 'Latest Ready Full/version evidence incomplete', {'run_id': source['id']}
                logs = subprocess.check_output(
                    ['gh', 'api', '--allow-escape-sequences', f'repos/{repo}/actions/jobs/{gate["id"]}/logs'],
                    text=True, timeout=30)
                if not metadata_log_matches(logs, pr, merge_sha):
                    return False, 'Prior gate checked different head/base/merge SHA', {'run_id': source['id']}
                again = api(f'repos/{repo}/pulls/{pr_num}')
                if error := pr_error(pr, again):
                    return False, error, {}
                if again.get('merge_commit_sha') != merge_sha:
                    return False, 'PR test-merge SHA changed during metadata validation', {}
                latest, latest_jobs, latest_error = metadata_source(
                    runs_for_head(), jobs_by_run, current_id,
                    current_run['workflow_id'], pr_num, head)
                latest_gate = next((j for j in latest_jobs or []
                                    if j['name'] == 'PR merge gate'), None)
                if (not latest or latest['id'] != source['id'] or latest_error
                        or latest.get('run_attempt') != source.get('run_attempt')
                        or latest.get('status') != 'completed'
                        or latest.get('conclusion') != 'success'
                        or not latest_gate or latest_gate['id'] != gate['id']):
                    missing_since = None
                    time.sleep(min(15, max(0, deadline - time.monotonic())))
                    continue
                return True, 'Metadata-only; prior identical Ready Full gate verified', {
                    'source_run': source['id'], 'source_gate_job': gate['id'],
                    'head': head, 'base': {'ref': pr['base']['ref'],
                                          'sha': pr['base']['sha']}, 'merge_sha': merge_sha}
            time.sleep(min(15, max(0, deadline - time.monotonic())))
        except (subprocess.CalledProcessError, subprocess.TimeoutExpired, ValueError, KeyError,
                json.JSONDecodeError) as exc:
            return False, f'Metadata validation API failed: {exc}', {}
    return False, 'Timed out waiting for identical Ready validation', {}


if __name__ == '__main__':
    event = json.load(open(os.environ['GITHUB_EVENT_PATH']))
    ok, reason, evidence = metadata_gate(event)
    summary = f'{"PASS" if ok else "FAIL"}: {reason}\\nEvidence: {evidence}\\n'
    print(summary)
    with open(os.environ['GITHUB_STEP_SUMMARY'], 'a') as out:
        out.write(summary.replace('\\n', '\n'))
    sys.exit(0 if ok else 1)
