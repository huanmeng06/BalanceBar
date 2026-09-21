#!/usr/bin/env bash

set -Eeuo pipefail

probe_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$probe_script_dir/../.." && pwd)"
app_bundle="${1:-$repo_root/build/BalanceBar.app}"
expected_deployment_target="${BALANCEBAR_EXPECTED_DEPLOYMENT_TARGET:-14.0}"

die() {
    printf 'deployment-artifact-smoke: error: %s\n' "$*" >&2
    exit 1
}

[[ -d "$app_bundle/Contents" ]] || die "app bundle does not exist: $app_bundle"
bundle_plist="$app_bundle/Contents/Info.plist"
executable="$app_bundle/Contents/MacOS/BalanceBar"
[[ -f "$bundle_plist" ]] || die "app Info.plist is missing"
[[ -x "$executable" ]] || die "app executable is missing or not executable: $executable"

minimum_system_version="$(plutil -extract LSMinimumSystemVersion raw -o - "$bundle_plist")"
[[ "$minimum_system_version" == "$expected_deployment_target" ]] \
    || die "app LSMinimumSystemVersion is $minimum_system_version; expected $expected_deployment_target"

file_info="$(file "$executable")"
[[ "$file_info" == *"Mach-O"* ]] || die "executable is not Mach-O: $file_info"

build_metadata="$(xcrun vtool -show-build "$executable")"
binary_minos="$(awk '$1 == "minos" { print $2; exit }' <<< "$build_metadata")"
[[ "$binary_minos" == "$expected_deployment_target" ]] \
    || die "binary minos is $binary_minos; expected $expected_deployment_target"

undefined_symbols="$(nm -u "$executable")"
if grep -Fq 'NSGlassEffectView' <<< "$undefined_symbols"; then
    die "binary directly links NSGlassEffectView; older macOS cannot load it"
fi

codesign --verify --verbose=2 "$app_bundle" \
    || die "codesign verification failed for $app_bundle"

printf 'deployment-artifact-smoke: bundle=%s minos=%s plist=%s\n' \
    "$app_bundle" "$binary_minos" "$minimum_system_version"
printf 'deployment-artifact-smoke: load-command and signature checks passed; this does not prove Dashboard GUI on this OS\n'
