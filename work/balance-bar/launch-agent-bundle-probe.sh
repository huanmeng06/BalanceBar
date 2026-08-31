#!/usr/bin/env bash

set -Eeuo pipefail

source_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
app_bundle="${1:-$source_dir/build/BalanceBar.app}"
expected_deployment_target="${BALANCEBAR_EXPECTED_DEPLOYMENT_TARGET:-14.0}"

die() {
    printf 'launch-agent-bundle-probe: error: %s\n' "$*" >&2
    exit 1
}

[[ -d "$app_bundle/Contents" ]] || die "app bundle does not exist: $app_bundle"
bundle_plist="$app_bundle/Contents/Info.plist"
launch_agents_dir="$app_bundle/Contents/Library/LaunchAgents"
agent_executable="$launch_agents_dir/BalanceBarChatGPTLaunchAgent"
agent_plist="$launch_agents_dir/balancebar-chatgpt-launch-agent.plist"

[[ -f "$bundle_plist" ]] || die "app Info.plist is missing"
[[ -x "$agent_executable" ]] || die "launch agent is missing or not executable"
[[ -f "$agent_plist" ]] || die "launch agent plist is missing"

bundle_identifier="$(plutil -extract CFBundleIdentifier raw -o - "$bundle_plist")"
minimum_system_version="$(plutil -extract LSMinimumSystemVersion raw -o - "$bundle_plist")"
[[ "$minimum_system_version" == "$expected_deployment_target" ]] \
    || die "app minimum OS is $minimum_system_version; expected $expected_deployment_target"

bundle_program="$(plutil -extract BundleProgram raw -o - "$agent_plist")"
[[ "$bundle_program" == "Contents/Library/LaunchAgents/BalanceBarChatGPTLaunchAgent" ]] \
    || die "BundleProgram is not app-bundle-relative: $bundle_program"
agent_label="$(plutil -extract Label raw -o - "$agent_plist")"
[[ "$agent_label" == "${bundle_identifier}.chatgpt-launch-agent" ]] \
    || die "launch agent label does not match bundle variant: $agent_label"
run_at_load="$(plutil -extract RunAtLoad raw -o - "$agent_plist")"
[[ "$run_at_load" == "true" ]] || die "launch agent must remain resident after registration"
if plutil -extract KeepAlive raw -o - "$agent_plist" >/dev/null 2>&1; then
    die "launch agent must not use KeepAlive relaunch behavior"
fi
if plutil -extract StartInterval raw -o - "$agent_plist" >/dev/null 2>&1; then
    die "launch agent must not poll with StartInterval"
fi

build_metadata="$(xcrun vtool -show-build "$agent_executable")"
binary_minimum_versions="$(awk '$1 == "minos" { print $2 }' <<< "$build_metadata" | sort -u)"
[[ "$binary_minimum_versions" == "$expected_deployment_target" ]] \
    || die "launch agent minimum OS is not $expected_deployment_target: $binary_minimum_versions"

codesign --verify --deep --strict "$app_bundle" \
    || die "deep code-signature verification failed"

printf 'launch-agent-bundle-probe: PASS (%s; label=%s; BundleProgram=%s; minOS=%s; signed)\n' \
    "$app_bundle" "$agent_label" "$bundle_program" "$expected_deployment_target"
