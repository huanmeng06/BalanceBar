#!/usr/bin/env python3
"""Only this run's Full or explicit PR-wide version exemption can pass."""
import json
import os
import sys


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


if __name__ == '__main__':
    event = json.load(open(os.environ['GITHUB_EVENT_PATH']))
    live = json.load(open(sys.argv[1])) if len(sys.argv) > 1 else None
    results = {key: os.environ.get(key.upper() + '_RESULT', 'missing') for key in ('scope', 'full', 'version')}
    ok, reason = verdict(os.environ['GITHUB_EVENT_NAME'], event.get('pull_request'), live,
                         results, os.environ.get('VERSION_ONLY') == 'true')
    summary = f"{'PASS' if ok else 'FAIL'}: {reason}\nEvent head: {event.get('pull_request', {}).get('head', {}).get('sha', os.environ['GITHUB_SHA'])}\nCheckout/merge SHA: {os.environ['GITHUB_SHA']}\nResults: {results}\n"
    print(summary)
    with open(os.environ['GITHUB_STEP_SUMMARY'], 'a') as out:
        out.write(summary)
    sys.exit(0 if ok else 1)
