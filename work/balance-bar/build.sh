#!/usr/bin/env bash

set -Eeuo pipefail

source_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
build_dir="$source_dir/build"
app_bundle="$build_dir/BalanceBar.app"
contents_dir="$app_bundle/Contents"
executable_dir="$contents_dir/MacOS"
resources_dir="$contents_dir/Resources"
module_cache_dir="$build_dir/swift-module-cache"
executable="$executable_dir/BalanceBar"

trap 'status=$?; printf "build-balancebar: command failed at line %s (exit %s): %s\n" "$LINENO" "$status" "$BASH_COMMAND" >&2' ERR

die() {
    printf 'build-balancebar: error: %s\n' "$*" >&2
    exit 1
}

[[ -d "$source_dir" ]] || die "source directory does not exist: $source_dir"

for required_file in \
    "$source_dir/Info.plist" \
    "$source_dir/BalanceBar.icns" \
    "$source_dir/CodexIcon.svg" \
    "$source_dir/Claude.svg" \
    "$source_dir/ClaudeThinking.svg"
do
    [[ -f "$required_file" ]] || die "required input is missing: $required_file"
done

printf 'build-balancebar: cleaning %s\n' "$build_dir"
rm -rf "$build_dir"
mkdir -p "$executable_dir" "$resources_dir" "$module_cache_dir"

swift_sources=()
while IFS= read -r source_file
do
    swift_sources+=("$source_file")
done < <(find "$source_dir" -type f -name '*.swift' -print | LC_ALL=C sort)

(( ${#swift_sources[@]} > 0 )) || die "no Swift source files found in $source_dir"

printf 'build-balancebar: compiling %d Swift source file(s)\n' "${#swift_sources[@]}"
printf '  %s\n' "${swift_sources[@]}"
swiftc \
    -parse-as-library \
    "${swift_sources[@]}" \
    -o "$executable" \
    -framework AppKit \
    -framework Foundation \
    -framework SwiftUI \
    -lsqlite3 \
    -module-cache-path "$module_cache_dir"

printf 'build-balancebar: copying bundle metadata and resources\n'
cp "$source_dir/Info.plist" "$contents_dir/Info.plist"
for resource_file in BalanceBar.icns CodexIcon.svg Claude.svg ClaudeThinking.svg
do
    cp "$source_dir/$resource_file" "$resources_dir/$resource_file"
done

printf 'build-balancebar: created %s\n' "$app_bundle"
