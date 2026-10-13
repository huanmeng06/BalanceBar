#!/usr/bin/env python3
"""Only this run's Full or explicit PR-wide version exemption can pass."""
import json
import os
import sys
import subprocess
import time


def verdict(event, event_pr, live_pr, results, version_only):
    if event != 'pull_request':
        return results['full'] == 'success', 'Manual Full (no PR merge credential)'
    if not live_pr or live_pr['state'] != 'open' or live_pr['draft'] or event_pr['draft']:
        return False, 'Draft/closed PR has no merge credential'
    for ref in ('head', 'base'):
        if live_pr[ref]['sha'] != event_pr[ref]['sha']:
            return False, f'PR {ref} changed since this event; rerun required'
    if results['scope'] != 'success':
        return False, 'Scope validation failed/cancelled/missing'
    if version_only:
        return results['version'] == 'success', 'PR-wide version-only exemption; XCTest NOT executed'
    return results['full'] == 'success', 'Full CI required for this event SHA'


def api(path):
    return json.loads(subprocess.check_output(['gh', 'api', path], text=True))


def wait_for_evidence(event, event_name):
    repo = os.environ['GITHUB_REPOSITORY']
    pr = event.get('pull_request')
    version_only = False
    if pr:
        classification = subprocess.check_output([
            'bash', '.github/scripts/classify-version-only-diff.sh',
            pr['base']['sha'], pr['head']['sha']], text=True).strip()
        version_only = classification == 'version-only'
    path = f"repos/{repo}/actions/runs/{os.environ['GITHUB_RUN_ID']}/attempts/{os.environ['GITHUB_RUN_ATTEMPT']}/jobs?per_page=100"
    names = {'scope': 'CI repository checks and PR scope',
             'full': 'Full CI (CLI, probes and serial XCTest)',
             'version': 'PR-wide version-only exemption (no XCTest)',
             'smoke': 'Pre-Liquid-Glass artifact smoke'}
    waiting = {'missing', 'queued', 'in_progress', 'waiting', 'pending', 'requested'}
    deadline = time.monotonic() + 23 * 60
    while True:
        live = api(f'repos/{repo}/pulls/{pr["number"]}') if pr else None
        jobs = api(path)['jobs']
        states = {j['name']: j.get('conclusion') or j['status'] for j in jobs}
        results = {key: states.get(name, 'missing') for key, name in names.items()}
        ok, reason = verdict(event_name, pr, live, results, version_only)
        # State/head changes invalidate even unfinished evidence immediately.
        if pr and (live['state'] != 'open' or live['draft'] or pr['draft'] or
                   any(live[ref]['sha'] != pr[ref]['sha'] for ref in ('head', 'base'))):
            return ok, reason, results
        lane = 'version' if version_only else 'full'
        if results['scope'] not in waiting and results['scope'] != 'success':
            return False, 'Repository/scope checks did not succeed', results
        if results['scope'] == 'success' and results[lane] not in waiting:
            # Preserve the advisory smoke execution without making its success required.
            if not ok or lane == 'version' or results['smoke'] not in waiting:
                return ok, reason, results
        if time.monotonic() >= deadline:
            return False, 'Timed out waiting for this run; no Full credential', results
        time.sleep(15)


if __name__ == '__main__':
    event = json.load(open(os.environ['GITHUB_EVENT_PATH']))
    ok, reason, results = wait_for_evidence(event, os.environ['GITHUB_EVENT_NAME'])
    summary = f"{'PASS' if ok else 'FAIL'}: {reason}\nEvent head: {event.get('pull_request', {}).get('head', {}).get('sha', os.environ['GITHUB_SHA'])}\nCheckout/merge SHA: {os.environ['GITHUB_SHA']}\nResults: {results}\n"
    print(summary)
    with open(os.environ['GITHUB_STEP_SUMMARY'], 'a') as out:
        out.write(summary)
    sys.exit(0 if ok else 1)
