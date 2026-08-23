#!/usr/bin/env bash

set -Eeuo pipefail

source_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
usage() {
    cat <<'EOF'
Usage: build.sh [production|dev]

Build the macOS app without changing the checked-in Info.plist.

  production  Build BalanceBar.app with the production Bundle ID (default).
  dev         Build BalanceBar-dev.app with the fixed development Bundle ID.
EOF
}

die() {
    printf 'build-balancebar: error: %s\n' "$*" >&2
    exit 1
}

if (( $# > 1 )); then
    usage >&2
    die "expected at most one build variant"
fi

variant="${1:-production}"
if [[ "$variant" == "-h" || "$variant" == "--help" ]]; then
    usage
    exit 0
fi

case "$variant" in
    production)
        build_dir="$source_dir/build"
        app_bundle="$build_dir/BalanceBar.app"
        bundle_identifier="com.huanmeng06.BalanceBar.app"
        bundle_name="BalanceBar"
        module_cache_dir="$build_dir/swift-module-cache"
        clean_paths=("$app_bundle" "$module_cache_dir")
        ;;
    dev)
        build_dir="$source_dir/build/dev"
        app_bundle="$build_dir/BalanceBar-dev.app"
        bundle_identifier="com.huanmeng06.BalanceBar.dev"
        bundle_name="BalanceBar Dev"
        module_cache_dir="$build_dir/swift-module-cache"
        clean_paths=("$build_dir")
        ;;
    *)
        usage >&2
        die "unknown build variant: $variant"
        ;;
esac

contents_dir="$app_bundle/Contents"
executable_dir="$contents_dir/MacOS"
resources_dir="$contents_dir/Resources"
executable="$executable_dir/BalanceBar"

balancebar_deployment_target="${BALANCEBAR_DEPLOYMENT_TARGET:-14.0}"
balancebar_build_arch="${BALANCEBAR_BUILD_ARCH:-$(uname -m)}"
balancebar_required_sdk_major="${BALANCEBAR_REQUIRED_SDK_MAJOR:-}"

[[ "$balancebar_deployment_target" =~ ^[0-9]+\.[0-9]+([.][0-9]+)?$ ]] \
    || die "invalid BALANCEBAR_DEPLOYMENT_TARGET: $balancebar_deployment_target"
case "$balancebar_build_arch" in
    arm64|x86_64) ;;
    *) die "unsupported BALANCEBAR_BUILD_ARCH: $balancebar_build_arch" ;;
esac

balancebar_sdk_path="$(xcrun --sdk macosx --show-sdk-path)"
balancebar_sdk_version="$(xcrun --sdk macosx --show-sdk-version)"
balancebar_sdk_major="${balancebar_sdk_version%%.*}"
balancebar_swift_target="${balancebar_build_arch}-apple-macosx${balancebar_deployment_target}"

if [[ -n "$balancebar_required_sdk_major" \
      && "$balancebar_sdk_major" != "$balancebar_required_sdk_major" ]]; then
    die "macOS SDK $balancebar_required_sdk_major.x is required; found $balancebar_sdk_version"
fi

trap 'status=$?; printf "build-balancebar: command failed at line %s (exit %s): %s\n" "$LINENO" "$status" "$BASH_COMMAND" >&2' ERR

[[ -d "$source_dir" ]] || die "source directory does not exist: $source_dir"

for required_file in \
    "$source_dir/Info.plist" \
    "$source_dir/BalanceBar.icns" \
    "$source_dir/GitHub.svg" \
    "$source_dir/CodexIcon.svg" \
    "$source_dir/Claude.svg" \
    "$source_dir/ClaudeThinking.svg"
do
    [[ -f "$required_file" ]] || die "required input is missing: $required_file"
done

printf 'build-balancebar: building %s variant in %s\n' "$variant" "$build_dir"
for clean_path in "${clean_paths[@]}"
do
    printf 'build-balancebar: cleaning %s\n' "$clean_path"
    rm -rf "$clean_path"
done
mkdir -p "$executable_dir" "$resources_dir" "$module_cache_dir"

swift_sources=()
while IFS= read -r source_file
do
    swift_sources+=("$source_file")
done < <(find "$source_dir" -type f -name '*.swift' -print | LC_ALL=C sort)

(( ${#swift_sources[@]} > 0 )) || die "no Swift source files found in $source_dir"

printf 'build-balancebar: compiling %d Swift source file(s)\n' "${#swift_sources[@]}"
printf 'build-balancebar: SDK %s; target %s\n' "$balancebar_sdk_version" "$balancebar_swift_target"
printf '  %s\n' "${swift_sources[@]}"
swiftc \
    -parse-as-library \
    -sdk "$balancebar_sdk_path" \
    -target "$balancebar_swift_target" \
    "${swift_sources[@]}" \
    -o "$executable" \
    -framework AppKit \
    -framework Foundation \
    -framework QuartzCore \
    -framework SwiftUI \
    -lsqlite3 \
    -module-cache-path "$module_cache_dir"

balancebar_build_metadata="$(xcrun vtool -show-build "$executable")"
balancebar_binary_minos="$(awk '$1 == "minos" { print $2; exit }' <<< "$balancebar_build_metadata")"
balancebar_binary_sdk="$(awk '$1 == "sdk" { print $2; exit }' <<< "$balancebar_build_metadata")"
[[ "$balancebar_binary_minos" == "$balancebar_deployment_target" ]] \
    || die "binary minimum OS is $balancebar_binary_minos; expected $balancebar_deployment_target"
balancebar_undefined_symbols="$(nm -u "$executable")"
if grep -Fq 'NSGlassEffectView' <<< "$balancebar_undefined_symbols"; then
    die "binary directly links NSGlassEffectView; runtime fallback would not be safe on older macOS"
fi
printf 'build-balancebar: verified binary minimum OS %s; SDK %s; macOS 26 glass remains runtime-linked\n' \
    "$balancebar_binary_minos" "$balancebar_binary_sdk"

printf 'build-balancebar: copying bundle metadata and resources\n'
bundle_plist="$contents_dir/Info.plist"
cp "$source_dir/Info.plist" "$bundle_plist"
plutil -replace CFBundleIdentifier -string "$bundle_identifier" "$bundle_plist"
bundle_minimum_system="$(plutil -extract LSMinimumSystemVersion raw -o - "$bundle_plist")"
[[ "$bundle_minimum_system" == "$balancebar_deployment_target" ]] \
    || die "Info.plist minimum OS is $bundle_minimum_system; expected $balancebar_deployment_target"
if [[ "$variant" == "dev" ]]; then
    plutil -replace CFBundleName -string "$bundle_name" "$bundle_plist"
    plutil -replace CFBundleDisplayName -string "$bundle_name" "$bundle_plist"
fi
for resource_file in BalanceBar.icns GitHub.svg CodexIcon.svg Claude.svg ClaudeThinking.svg
do
    cp "$source_dir/$resource_file" "$resources_dir/$resource_file"
done

printf 'build-balancebar: ad-hoc signing complete bundle\n'
codesign --force --deep --sign - "$app_bundle"
codesign --verify --deep --strict "$app_bundle"

printf 'build-balancebar: created %s (Bundle ID %s)\n' "$app_bundle" "$bundle_identifier"
