#!/usr/bin/env bash

set -Eeuo pipefail

die() {
    printf 'create-dmg: %s\n' "$*" >&2
    exit 1
}

app_path=""
version=""
output_path=""

while (( $# > 0 )); do
    case "$1" in
        --app)
            app_path="${2:-}"
            shift 2
            ;;
        --version)
            version="${2:-}"
            shift 2
            ;;
        --output)
            output_path="${2:-}"
            shift 2
            ;;
        *)
            die "unknown argument: $1"
            ;;
    esac
done

[[ -d "$app_path" ]] || die "app bundle does not exist: $app_path"
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "invalid version: $version"
[[ -n "$output_path" ]] || die "--output is required"

staging_parent="${RUNNER_TEMP:-${TMPDIR:-/tmp}}"
staging_dir="$(mktemp -d "${staging_parent%/}/balancebar-dmg.XXXXXX")"
cleanup() {
    rm -rf -- "$staging_dir"
}
trap cleanup EXIT

volume_root="$staging_dir/volume"
mkdir -p "$volume_root" "$(dirname "$output_path")"
ditto "$app_path" "$volume_root/BalanceBar.app"
ln -s /Applications "$volume_root/Applications"

hdiutil create \
    -volname "BalanceBar ${version}" \
    -srcfolder "$volume_root" \
    -ov \
    -format UDZO \
    "$output_path"
hdiutil verify "$output_path"

printf 'create-dmg: created %s with BalanceBar.app and Applications shortcut\n' \
    "$output_path"
