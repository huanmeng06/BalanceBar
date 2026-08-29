#!/usr/bin/env bash

set -Eeuo pipefail

source_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
resource_root="$source_dir/lang"
bundle_root="${1:-}"
localization_directories=(en.lproj zh-Hans.lproj zh-Hant-TW.lproj zh-Hant-HK.lproj ja.lproj ko.lproj es.lproj de.lproj fr.lproj pt.lproj ru.lproj it.lproj)

die() {
    printf 'localization-resource-probe: error: %s\n' "$*" >&2
    exit 1
}

source_keys="$(
    sed -nE 's/^    case .* = "([^"]+)".*/\1/p' "$source_dir/Sources/AppCore/LocalizationKeys.swift" \
        | LC_ALL=C sort
)"
source_key_count="$(printf '%s\n' "$source_keys" | awk 'NF { count += 1 } END { print count + 0 }')"
source_unique_count="$(printf '%s\n' "$source_keys" | LC_ALL=C uniq | awk 'NF { count += 1 } END { print count + 0 }')"
[[ "$source_key_count" == "$source_unique_count" ]] || die "LocalizationKey contains duplicate raw keys"

for localization_directory in "${localization_directories[@]}"; do
    localization_file="$resource_root/$localization_directory/Localizable.strings"
    [[ -f "$localization_file" ]] || die "source resource is missing: $localization_file"

    resource_keys="$(
        sed -nE 's/^"([^"]+)".*/\1/p' "$localization_file" \
            | LC_ALL=C sort
    )"
    resource_key_count="$(printf '%s\n' "$resource_keys" | awk 'NF { count += 1 } END { print count + 0 }')"
    resource_unique_count="$(printf '%s\n' "$resource_keys" | LC_ALL=C uniq | awk 'NF { count += 1 } END { print count + 0 }')"
    [[ "$resource_key_count" == "$source_key_count" ]] \
        || die "$localization_directory has $resource_key_count keys; expected $source_key_count"
    [[ "$resource_key_count" == "$resource_unique_count" ]] \
        || die "$localization_directory contains duplicate keys"
    [[ "$resource_keys" == "$source_keys" ]] \
        || die "$localization_directory key set differs from LocalizationKey"
done

if [[ -n "$bundle_root" ]]; then
    resources_dir="$bundle_root/Contents/Resources"
    [[ -d "$resources_dir" ]] || die "bundle Resources directory is missing: $resources_dir"
    for localization_directory in "${localization_directories[@]}"; do
        packaged_file="$resources_dir/$localization_directory/Localizable.strings"
        [[ -s "$packaged_file" ]] \
            || die "packaged resource is missing or empty: $packaged_file"
    done
fi

printf 'localization-resource-probe: PASS (%s keys, %s languages' "$source_key_count" "${#localization_directories[@]}"
if [[ -n "$bundle_root" ]]; then
    printf ', bundle=%s' "$bundle_root"
fi
printf ')\n'
