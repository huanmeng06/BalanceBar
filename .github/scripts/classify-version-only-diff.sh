#!/usr/bin/env bash

set -Eeuo pipefail

plist_path='Resources/Info.plist'

full_result() {
    printf '%s\n' 'full'
    exit 0
}

# One argument retains the legacy single-commit interface. PR callers
# MUST pass base and head; compare the merge base, including every PR commit.
if [[ "$#" -eq 2 ]]; then
    commit_input="$2"
    parent_sha="$(git merge-base "$1" "$2" 2>/dev/null)" || full_result
elif [[ "$#" -eq 1 ]]; then
    commit_input="$1"
    parent_sha="$(git rev-parse "${1}^" 2>/dev/null)" || full_result
    [[ "$(git rev-list --parents -n 1 "$1" | awk '{print NF}')" == 2 ]] || full_result
else
    printf 'usage: %s <base> <head> (or legacy <commit>)\n' "$0" >&2
    exit 2
fi
commit_sha="$(git rev-parse --verify "${commit_input}^{commit}" 2>/dev/null)" || full_result
changed_files="$(git diff --name-status --no-renames "$parent_sha" "$commit_sha" -- 2>/dev/null)" || full_result
[[ "$changed_files" == $'M\tResources/Info.plist' ]] || full_result

if ! old_mode="$(git ls-tree "$parent_sha" -- "$plist_path" | awk 'NF { print $1 }')"; then
    full_result
fi
if ! new_mode="$(git ls-tree "$commit_sha" -- "$plist_path" | awk 'NF { print $1 }')"; then
    full_result
fi
if [[ "$old_mode" != '100644' || "$new_mode" != '100644' ]]; then
    full_result
fi

old_file="$(mktemp)"
new_file="$(mktemp)"
old_normalized="$(mktemp)"
new_normalized="$(mktemp)"
cleanup() {
    rm -f "$old_file" "$new_file" "$old_normalized" "$new_normalized"
}
trap cleanup EXIT

if ! git show "${parent_sha}:${plist_path}" > "$old_file" 2>/dev/null; then
    full_result
fi
if ! git show "${commit_sha}:${plist_path}" > "$new_file" 2>/dev/null; then
    full_result
fi

# Portable plist validation for the Linux scope job. Require two changed,
# nonempty string fields; textual normalization below rejects all other edits.
if ! python3 - "$old_file" "$new_file" <<'PYPLIST'
import plistlib, sys
try:
    old, new = [plistlib.load(open(p, 'rb')) for p in sys.argv[1:]]
    for key in ('CFBundleShortVersionString', 'CFBundleVersion'):
        if not all(isinstance(v[key], str) and v[key] for v in (old, new)) or old[key] == new[key]:
            raise ValueError('Both version strings must change')
except Exception:
    sys.exit(1)
PYPLIST
then
    full_result
fi

normalize_plist() {
    local input_path="$1"
    local output_path="$2"

    awk '
        function normalize_version_line(line) {
            if (line !~ /^[[:space:]]*<string>[^<]*<\/string>[[:space:]]*$/) {
                exit 2
            }
            sub(/<string>[^<]*<\/string>/, "<string>__BALANCEBAR_VERSION__<\/string>", line)
            return line
        }

        /^[[:space:]]*<key>CFBundleShortVersionString<\/key>[[:space:]]*$/ {
            if (short_seen++ != 0) {
                exit 3
            }
            print
            if (getline <= 0) {
                exit 4
            }
            print normalize_version_line($0)
            next
        }

        /^[[:space:]]*<key>CFBundleVersion<\/key>[[:space:]]*$/ {
            if (build_seen++ != 0) {
                exit 5
            }
            print
            if (getline <= 0) {
                exit 6
            }
            print normalize_version_line($0)
            next
        }

        { print }

        END {
            if (short_seen != 1 || build_seen != 1) {
                exit 7
            }
        }
    ' "$input_path" > "$output_path"
}

if ! normalize_plist "$old_file" "$old_normalized"; then
    full_result
fi
if ! normalize_plist "$new_file" "$new_normalized"; then
    full_result
fi

if ! cmp -s "$old_normalized" "$new_normalized"; then
    full_result
fi

printf '%s\n' 'version-only'
