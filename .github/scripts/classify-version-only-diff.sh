#!/usr/bin/env bash

set -Eeuo pipefail

plist_path='work/balance-bar/Info.plist'

full_result() {
    printf '%s\n' 'full'
    exit 0
}

if [[ "$#" -ne 1 ]]; then
    printf 'usage: %s <commit>\n' "$0" >&2
    exit 2
fi

commit_input="$1"
if ! commit_sha="$(git rev-parse --verify "${commit_input}^{commit}" 2>/dev/null)"; then
    full_result
fi

if ! parents_line="$(git rev-list --parents -n 1 "$commit_sha" 2>/dev/null)"; then
    full_result
fi
read -r -a parent_fields <<< "$parents_line"
if [[ "${#parent_fields[@]}" -ne 2 ]]; then
    full_result
fi
parent_sha="${parent_fields[1]}"

if ! changed_files="$(git diff-tree \
    --no-commit-id \
    --name-status \
    --no-renames \
    -r \
    "$commit_sha" 2>/dev/null)"; then
    full_result
fi
if [[ "$changed_files" != $'M\twork/balance-bar/Info.plist' ]]; then
    full_result
fi

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

if ! plutil -lint "$old_file" >/dev/null 2>&1; then
    full_result
fi
if ! plutil -lint "$new_file" >/dev/null 2>&1; then
    full_result
fi

if ! old_short="$(plutil -extract CFBundleShortVersionString raw -o - "$old_file" 2>/dev/null)"; then
    full_result
fi
if ! new_short="$(plutil -extract CFBundleShortVersionString raw -o - "$new_file" 2>/dev/null)"; then
    full_result
fi
if ! old_build="$(plutil -extract CFBundleVersion raw -o - "$old_file" 2>/dev/null)"; then
    full_result
fi
if ! new_build="$(plutil -extract CFBundleVersion raw -o - "$new_file" 2>/dev/null)"; then
    full_result
fi
if [[ -z "$old_short" || -z "$new_short" || "$old_short" == "$new_short" ]]; then
    full_result
fi
if [[ -z "$old_build" || -z "$new_build" || "$old_build" == "$new_build" ]]; then
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
