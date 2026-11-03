#!/usr/bin/env python3
"""Conservative PR-wide fast-lane scope. Unknown/deleted/renamed inputs build."""
import subprocess
import sys


def classify(entries):
    build = probes = test_build = False
    for status, path in entries:
        test_build |= path.startswith(('Tests/', 'BalanceBar.xcodeproj/'))
        documentation = path.endswith('.md') or path in (
            'LICENSE', 'CODE_OF_CONDUCT.md', '.github/PULL_REQUEST_TEMPLATE.md')
        if status not in ('A', 'M') or not documentation:
            build = probes = True
    return build, probes, test_build


def docs_only(entries):
    """Ready docs exemption: a non-empty diff of only added/modified docs."""
    return bool(entries) and not classify(entries)[0]


if __name__ == '__main__':
    base = subprocess.check_output(['git', 'merge-base', sys.argv[1], sys.argv[2]], text=True).strip()
    raw = subprocess.check_output(['git', 'diff', '--name-status', '--no-renames', '-z', base, sys.argv[2]])
    fields = raw.decode().split('\0')[:-1]
    entries = list(zip(fields[::2], fields[1::2]))
    build, probes, test_build = classify(entries)
    action = 'build-for-testing' if test_build else 'build'
    print(f'build={str(build).lower()}\nprobes={str(probes).lower()}\naction={action}\n'
          f'docs_only={str(docs_only(entries)).lower()}')
