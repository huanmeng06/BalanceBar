#!/usr/bin/env python3
"""Every planned XCTest shard must report a passing, non-empty result."""
import json
import sys
from pathlib import Path

PLAN = Path(__file__).resolve().parent.parent / 'ci-test-shards.txt'


def planned_shards(plan_text):
    listed = {int(line.split()[0]) for line in plan_text.splitlines()
              if line.strip() and not line.startswith('#')}
    return set(range(1, max(listed) + 2))


def totals(summaries, expected):
    if set(summaries) != expected:
        raise SystemExit(f'XCTest shards reported {sorted(summaries)}; expected {sorted(expected)}')
    for shard, data in sorted(summaries.items()):
        if (data.get('result') != 'Passed' or data.get('failedTests', 1) != 0
                or data.get('totalTestCount', 0) <= 0):
            raise SystemExit(f'XCTest shard {shard} did not pass with tests: {data}')
    keys = ('totalTestCount', 'passedTests', 'skippedTests', 'failedTests')
    return {key: sum(d.get(key, 0) for d in summaries.values()) for key in keys}


if __name__ == '__main__':
    root = Path(sys.argv[1])
    summaries = {int(p.stem.split('-')[1]): json.loads(p.read_text())
                 for p in root.glob('shard-*.json')}
    result = totals(summaries, planned_shards(PLAN.read_text()))
    print('XCTest shards ' + ', '.join(
        f"{k}={summaries[k].get('totalTestCount')}" for k in sorted(summaries))
        + f"; all shards: {result}")
