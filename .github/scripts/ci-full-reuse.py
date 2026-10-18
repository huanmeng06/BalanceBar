#!/usr/bin/env python3
"""Validate a strictly version-only increment after a completed Ready Full run."""
import json
import os
import re
import subprocess
import sys


WORKFLOW_PATH = '.github/workflows/build-and-test.yml'
SCOPE = 'CI repository checks and PR scope'
FULL = 'Full CI (CLI, probes and serial XCTest)'
VERSION = 'PR-wide version-only exemption (no XCTest)'
SMOKE = 'Pre-Liquid-Glass artifact smoke'
GATE = 'PR merge gate'
REUSE = 'Verified prior Full reuse (version increment; no XCTest)'
WAITING = {'queued', 'in_progress', 'waiting', 'pending', 'requested'}
MAX_RUN_PAGES = 10


class EvidenceError(Exception):
    """A missing, inconsistent, or unverifiable hosted evidence fact."""


def api(path, timeout=20):
    return json.loads(subprocess.check_output(
        ['gh', 'api', path], text=True, timeout=timeout))


def api_text(path, timeout=30):
    return subprocess.check_output(
        ['gh', 'api', path],
        text=True, timeout=timeout)


def git(*args):
    return subprocess.check_output(
        ['git', *args], text=True, stderr=subprocess.DEVNULL).strip()


def is_ancestor(old, new):
    return subprocess.run(
        ['git', 'merge-base', '--is-ancestor', old, new],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode == 0


def job_state(job):
    if not job:
        return 'missing'
    return job.get('conclusion') or job.get('status') or 'missing'


def fresh_execution(job, since):
    return bool(job and job.get('started_at') and job.get('completed_at')
                and job['started_at'] >= since and job['completed_at'] >= since)


def job_identity(job, run_id, attempt, head):
    return (job and str(job.get('run_id')) == str(run_id)
            and job.get('run_attempt') == attempt
            and job.get('head_sha') == head
            and job.get('id'))


def unique_job(jobs, name):
    matches = [job for job in jobs if job.get('name') == name]
    if len(matches) != 1:
        raise EvidenceError(f'{name} job count is {len(matches)}')
    return matches[0]


def paged_jobs(repo, run_id):
    jobs = []
    total = None
    for page in range(1, MAX_RUN_PAGES + 1):
        data = api(f'repos/{repo}/actions/runs/{run_id}/jobs?filter=all&per_page=100&page={page}')
        page_jobs = data.get('jobs')
        if not isinstance(page_jobs, list):
            raise EvidenceError('incomplete historical jobs response')
        jobs.extend(page_jobs)
        total = data.get('total_count')
        if not isinstance(total, int) or len(jobs) >= total:
            if not isinstance(total, int):
                raise EvidenceError('historical jobs total missing')
            return jobs
        if not page_jobs:
            raise EvidenceError('incomplete historical jobs response')
    raise EvidenceError('historical jobs pagination exceeds safety bound')


def prior_scope_job(repo, run_id, attempt, head, since, current_jobs):
    current = [job for job in current_jobs if job.get('name') == SCOPE]
    if len(current) > 1:
        raise EvidenceError('scope job is duplicated in current attempt')
    if current:
        job = current[0]
        if not job_identity(job, run_id, attempt, head):
            raise EvidenceError('current scope identity mismatch')
        if job_state(job) != 'success':
            raise EvidenceError(f'current scope is {job_state(job)}')
        if fresh_execution(job, since):
            return job
        # A carried scope may have the current attempt number in a partial API
        # response, but its old timestamps do not satisfy the current attempt.
        # Fall through to the complete attempt history, just as the live gate
        # does. A current failure/skipped result above remains authoritative.

    history = [job for job in paged_jobs(repo, run_id)
               if job.get('name') == SCOPE
               and str(job.get('run_id')) == str(run_id)
               and job.get('head_sha') == head
               and isinstance(job.get('run_attempt'), int)]
    older = [job for job in history if job['run_attempt'] < attempt]
    if not older:
        raise EvidenceError('no successful scope evidence')
    latest_attempt = max(job['run_attempt'] for job in older)
    latest = [job for job in older if job['run_attempt'] == latest_attempt]
    if any(job_state(job) != 'success' for job in latest):
        raise EvidenceError('latest carried scope is not successful')
    latest.sort(key=lambda job: job['id'])
    return latest[0]


def normalize_log_lines(log):
    ansi = re.compile(r'\x1b\[[0-?]*[ -/]*[@-~]')
    lines = []
    for raw in log.splitlines():
        line = ansi.sub('', raw).lstrip('\ufeff')
        if 'Z ' in line:
            line = line.split('Z ', 1)[1]
        lines.append(line.strip())
    return lines


def log_value(lines, prefix):
    for line in lines:
        if line.startswith(prefix):
            return line[len(prefix):]
    return None


def parse_identity(lines):
    value = log_value(lines, 'Validation identity: ')
    if not value:
        raise EvidenceError('prior gate identity record missing')
    fields = {}
    for field in value.split('; '):
        key, separator, item = field.partition(' ')
        if not separator:
            raise EvidenceError('prior gate identity record malformed')
        fields[key] = item
    required = ('PR', 'workflow', 'run', 'attempt', 'gate', 'event', 'draft')
    if any(key not in fields for key in required):
        raise EvidenceError('prior gate identity record incomplete')
    try:
        fields['pr_number'] = int(fields['PR'].lstrip('#'))
        fields['workflow_id'] = int(fields['workflow'])
        fields['run_id'] = int(fields['run'])
        fields['attempt'] = int(fields['attempt'])
        fields['gate_job_id'] = int(fields['gate'])
    except ValueError as exc:
        raise EvidenceError('prior gate identity record has invalid numbers') from exc
    return fields


def verify_merge_commit(repo, merge_sha, base_sha, head_sha):
    if not merge_sha or merge_sha in {'None', 'null'}:
        raise EvidenceError('prior PR merge SHA missing')
    commit = api(f'repos/{repo}/commits/{merge_sha}')
    if commit.get('sha') != merge_sha:
        raise EvidenceError('prior PR merge SHA identity mismatch')
    parents = [parent.get('sha') for parent in commit.get('parents', [])]
    if len(parents) != 2 or set(parents) != {base_sha, head_sha}:
        raise EvidenceError('prior PR merge SHA is not the recorded base/head merge')


def validate_gate_log(repo, run, attempt, gate_job, pr_number, workflow_id,
                      expected_head, base_ref, base_sha):
    log = api_text(f'repos/{repo}/actions/jobs/{gate_job["id"]}/logs')
    lines = normalize_log_lines(log)
    identity = parse_identity(lines)
    if identity['pr_number'] != pr_number:
        raise EvidenceError('prior gate PR identity mismatch')
    if identity['workflow_id'] != workflow_id:
        raise EvidenceError('prior gate workflow identity mismatch')
    if identity['run_id'] != run['id'] or identity['attempt'] != attempt:
        raise EvidenceError('prior gate run/attempt identity mismatch')
    if identity['gate_job_id'] != gate_job['id']:
        raise EvidenceError('prior gate job identity mismatch')
    if identity['draft'] != 'false' or not identity['event'].startswith('pull_request/'):
        raise EvidenceError('prior gate was not a Ready pull_request validation')

    if 'PASS: Full CI for event head/base' not in lines:
        raise EvidenceError('prior gate did not record a Full PASS')
    event_head = log_value(lines, 'Event head: ')
    base = log_value(lines, 'Base: ')
    merge_sha = log_value(lines, 'Checkout/merge SHA: ')
    if event_head != expected_head or base != f'{base_ref} / {base_sha}':
        raise EvidenceError('prior gate logged a different head/base')
    checkout_merge = log_value(lines, 'Checkout/merge SHA: ')
    verify_merge_commit(repo, checkout_merge, base_sha, expected_head)
    return {'merge_sha': checkout_merge, 'log': log}


def inspect_full_run(repo, run, pr_number, expected_head, base_ref, base_sha,
                     workflow_id):
    if (run.get('event') != 'pull_request' or run.get('head_sha') != expected_head
            or run.get('workflow_id') != workflow_id
            or run.get('path') != WORKFLOW_PATH):
        raise EvidenceError('prior run workflow/head identity mismatch')
    if run.get('status') != 'completed' or run.get('conclusion') != 'success':
        raise EvidenceError(f'latest prior run is {run.get("status")}/{run.get("conclusion")}')
    try:
        attempt = int(run['run_attempt'])
    except (KeyError, TypeError, ValueError) as exc:
        raise EvidenceError('prior run attempt missing') from exc
    attempt_info = api(f'repos/{repo}/actions/runs/{run["id"]}/attempts/{attempt}')
    if (str(attempt_info.get('id')) != str(run['id'])
            or attempt_info.get('head_sha') != expected_head
            or attempt_info.get('run_attempt') != attempt
            or attempt_info.get('workflow_id') != workflow_id
            or not attempt_info.get('run_started_at')):
        raise EvidenceError('prior attempt identity missing/mismatched')
    since = attempt_info['run_started_at']
    current_jobs_data = api(
        f'repos/{repo}/actions/runs/{run["id"]}/attempts/{attempt}/jobs?per_page=100')
    current_jobs = current_jobs_data.get('jobs')
    if (not isinstance(current_jobs, list)
            or current_jobs_data.get('total_count') != len(current_jobs)):
        raise EvidenceError('prior attempt jobs response incomplete')

    scope = prior_scope_job(repo, run['id'], attempt, expected_head, since, current_jobs)
    full = unique_job(current_jobs, FULL)
    version = unique_job(current_jobs, VERSION)
    smoke = unique_job(current_jobs, SMOKE)
    gate = unique_job(current_jobs, GATE)
    for name, job in ((FULL, full), (SMOKE, smoke), (GATE, gate)):
        if not job_identity(job, run['id'], attempt, expected_head):
            raise EvidenceError(f'{name} identity mismatch')
        if not fresh_execution(job, since):
            raise EvidenceError(f'{name} is not a fresh attempt execution')
    if job_state(scope) != 'success' or job_state(full) != 'success':
        raise EvidenceError('prior scope or Full job did not succeed')
    if job_state(version) != 'skipped':
        raise EvidenceError('prior Full run did not preserve the version job boundary')
    if job_state(smoke) not in ('success', 'failure'):
        raise EvidenceError('prior smoke was not completed with advisory semantics')
    if job_state(gate) != 'success':
        raise EvidenceError('prior PR merge gate did not succeed')
    log_evidence = validate_gate_log(
        repo, run, attempt, gate, pr_number, workflow_id,
        expected_head, base_ref, base_sha)
    return {
        'run_id': run['id'],
        'attempt': attempt,
        'gate_job_id': gate['id'],
        'head': expected_head,
        'base_ref': base_ref,
        'base_sha': base_sha,
        'merge_sha': log_evidence['merge_sha'],
        'smoke': job_state(smoke),
        'scope_job_id': scope['id'],
        'full_job_id': full['id'],
    }


def validate_version_chain(previous_head, current_head):
    if previous_head == current_head or not is_ancestor(previous_head, current_head):
        raise EvidenceError('prior Full head is not a strict ancestor of current head')
    commits = git('rev-list', '--reverse', f'{previous_head}..{current_head}').splitlines()
    if not commits:
        raise EvidenceError('version increment has no commits')
    classifier = os.path.join('.github', 'scripts', 'classify-version-only-diff.sh')
    for commit in commits:
        parents = git('rev-list', '--parents', '-n', '1', commit).split()
        if len(parents) != 2:
            raise EvidenceError('version increment contains a merge/root commit')
        result = subprocess.run(
            ['bash', classifier, commit], text=True,
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=15)
        if result.returncode != 0 or result.stdout.strip() != 'version-only':
            raise EvidenceError(f'commit {commit} is not a strict version-only increment')
    aggregate = subprocess.run(
        ['bash', classifier, previous_head, current_head], text=True,
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=15)
    if aggregate.returncode != 0 or aggregate.stdout.strip() != 'version-only':
        raise EvidenceError('aggregate version increment is not strictly version-only')
    return len(commits)


def list_workflow_runs_for_head(repo, workflow_id, head_sha):
    runs = []
    for page in range(1, MAX_RUN_PAGES + 1):
        data = api(
            f'repos/{repo}/actions/workflows/{workflow_id}/runs?event=pull_request'
            f'&head_sha={head_sha}&per_page=100&page={page}')
        page_runs = data.get('workflow_runs')
        total = data.get('total_count')
        if not isinstance(page_runs, list) or not isinstance(total, int):
            raise EvidenceError('head-scoped workflow run response incomplete')
        runs.extend(page_runs)
        if len(runs) >= total:
            return runs
        if not page_runs:
            raise EvidenceError('head-scoped workflow run pagination incomplete')
    raise EvidenceError('head-scoped workflow run pagination exceeds safety bound')


def run_belongs_to_pr(run, pr_number, head_ref):
    if any(pr.get('number') == pr_number for pr in run.get('pull_requests', [])):
        return True
    # Closed/merged historical runs may omit pull_requests. The immutable gate
    # log still binds the PR number before a candidate can be accepted.
    return run.get('head_branch') == head_ref


def nearest_prior_head(runs, current_head):
    heads = {run.get('head_sha') for run in runs if run.get('head_sha')
             and run.get('head_sha') != current_head
             and is_ancestor(run['head_sha'], current_head)}
    if not heads:
        raise EvidenceError('no prior ancestor validation head found')
    distances = {}
    for head in heads:
        try:
            distances[head] = int(git('rev-list', '--count', f'{head}..{current_head}'))
        except subprocess.CalledProcessError:
            continue
    if not distances:
        raise EvidenceError('prior validation heads are not locally auditable')
    nearest = min(distances.values())
    choices = [head for head, distance in distances.items() if distance == nearest]
    if len(choices) != 1:
        raise EvidenceError('ambiguous nearest prior validation head')
    return choices[0]


def prior_commit_heads(base_sha, current_head):
    commits = git(
        'rev-list', '--first-parent', '--reverse', f'{base_sha}..{current_head}'
    ).splitlines()
    if not commits:
        raise EvidenceError('version increment has no auditable prior commits')
    return commits


def find_nearest_prior_runs(repo, workflow_id, pr_number, head_ref,
                            current_run_id, base_sha, current_head):
    # Query Actions by each PR commit head instead of scanning the repository's
    # entire workflow history. Large repositories can exceed the global
    # workflow-run pagination bound even when this PR has a single valid prior
    # Full run.
    for candidate_head in reversed(prior_commit_heads(base_sha, current_head)):
        candidates = [run for run in list_workflow_runs_for_head(
            repo, workflow_id, candidate_head
        ) if str(run.get('id')) != str(current_run_id)
            and run.get('workflow_id') == workflow_id
            and run.get('event') == 'pull_request'
            and run.get('head_sha') == candidate_head
            and run_belongs_to_pr(run, pr_number, head_ref)]
        if candidates:
            candidates.sort(key=lambda run: run.get('id', 0), reverse=True)
            return candidate_head, candidates
    raise EvidenceError('no prior ancestor validation head found')


def evaluate(base_sha, head_sha):
    event_path = os.environ.get('GITHUB_EVENT_PATH')
    if not event_path:
        raise EvidenceError('event payload unavailable')
    with open(event_path, encoding='utf-8') as source:
        event = json.load(source)
    if os.environ.get('GITHUB_EVENT_NAME') != 'pull_request' or event.get('action') != 'synchronize':
        raise EvidenceError('only Ready synchronize events may reuse Full evidence')
    pr = event.get('pull_request') or {}
    if pr.get('draft') or pr.get('state') not in (None, 'open'):
        raise EvidenceError('current PR is not Ready/open')
    pr_number = pr.get('number')
    base = pr.get('base') or {}
    head = pr.get('head') or {}
    if (not isinstance(pr_number, int) or base.get('sha') != base_sha
            or head.get('sha') != head_sha or not base.get('ref')
            or not head.get('ref')):
        raise EvidenceError('current event head/base identity missing or changed')

    repo = os.environ.get('GITHUB_REPOSITORY')
    current_run_id = os.environ.get('GITHUB_RUN_ID')
    current_attempt = os.environ.get('GITHUB_RUN_ATTEMPT')
    if not repo or not current_run_id or not current_attempt:
        raise EvidenceError('current workflow identity environment missing')
    current_run = api(f'repos/{repo}/actions/runs/{current_run_id}')
    try:
        attempt = int(current_attempt)
    except ValueError as exc:
        raise EvidenceError('current run attempt invalid') from exc
    if (str(current_run.get('id')) != str(current_run_id)
            or current_run.get('event') != 'pull_request'
            or current_run.get('head_sha') != head_sha
            or current_run.get('run_attempt') != attempt
            or current_run.get('path') != WORKFLOW_PATH
            or not current_run.get('workflow_id')):
        raise EvidenceError('current workflow/run identity missing or mismatched')
    workflow_id = current_run['workflow_id']

    live = api(f'repos/{repo}/pulls/{pr_number}')
    if (live.get('state') != 'open' or live.get('draft')
            or live.get('head', {}).get('sha') != head_sha
            or live.get('base', {}).get('sha') != base_sha
            or live.get('base', {}).get('ref') != base['ref']
            or not live.get('merge_commit_sha')):
        raise EvidenceError('live PR identity changed or merge identity unavailable')

    candidate_head, candidates = find_nearest_prior_runs(
        repo, workflow_id, pr_number, head['ref'], current_run_id,
        base_sha, head_sha
    )
    commits = validate_version_chain(candidate_head, head_sha)
    # The newest run for the candidate head wins. A newer failure, cancellation,
    # queue, Draft validation, or partial run must hide an older green result.
    evidence = inspect_full_run(
        repo, candidates[0], pr_number, candidate_head, base['ref'], base_sha,
        workflow_id)
    evidence['increment_commits'] = commits
    return evidence


def summary(evidence, error):
    if evidence:
        return ('Validated prior Ready Full reuse: '
                + json.dumps(evidence, sort_keys=True, separators=(',', ':')))
    return f'Full reuse unavailable; fall back to real Full CI: {error}'


def main():
    if len(sys.argv) != 3 and len(sys.argv) != 4:
        print('usage: ci-full-reuse.py <base-sha> <head-sha> [--require]', file=sys.stderr)
        return 2
    require = len(sys.argv) == 4 and sys.argv[3] == '--require'
    if len(sys.argv) == 4 and not require:
        print('usage: ci-full-reuse.py <base-sha> <head-sha> [--require]', file=sys.stderr)
        return 2
    evidence = None
    error = None
    try:
        evidence = evaluate(sys.argv[1], sys.argv[2])
    except (EvidenceError, OSError, subprocess.CalledProcessError,
            subprocess.TimeoutExpired, json.JSONDecodeError, KeyError,
            TypeError, ValueError, AttributeError, IndexError) as exc:
        error = str(exc) or exc.__class__.__name__
    ok = evidence is not None
    print(f'reuse_full={str(ok).lower()}')
    if ok:
        print('reuse_reason=' +
              f'prior-run-{evidence["run_id"]}-attempt-{evidence["attempt"]}-'
              f'gate-{evidence["gate_job_id"]}-commits-{evidence["increment_commits"]}')
    else:
        print('reuse_reason=fall-back-to-full')
    step_summary = os.environ.get('GITHUB_STEP_SUMMARY')
    if step_summary:
        with open(step_summary, 'a', encoding='utf-8') as out:
            out.write(('FULL_REUSE: PASS\n' if ok else 'FULL_REUSE: FAIL\n')
                      + summary(evidence, error or 'unknown') + '\n')
    if not ok and require:
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
