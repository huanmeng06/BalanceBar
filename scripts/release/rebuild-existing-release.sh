#!/usr/bin/env bash

set -Eeuo pipefail

die() {
    printf 'rebuild-existing-release: %s\n' "$*" >&2
    exit 1
}

repository="${GITHUB_REPOSITORY:-}"
version="${REBUILD_VERSION:-}"
target_sha="${REBUILD_TARGET_SHA:-}"
replacement_dmg="${REBUILD_DMG:-}"
confirm_replace="${REBUILD_CONFIRM_REPLACE:-false}"

[[ "$confirm_replace" == "true" ]] || die "REBUILD_CONFIRM_REPLACE=true is required"
[[ -n "$repository" ]] || die "GITHUB_REPOSITORY is required"
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "invalid version: $version"
[[ "$target_sha" =~ ^[0-9a-f]{40}$ ]] || die "invalid target SHA: $target_sha"
[[ -f "$replacement_dmg" ]] || die "replacement DMG does not exist: $replacement_dmg"

tag="v${version}"
asset_name="BalanceBar-${version}.dmg"
plist_version="$(plutil -extract CFBundleShortVersionString raw -o - work/balance-bar/Info.plist)"
[[ "$plist_version" == "$version" ]] \
    || die "Info.plist version is $plist_version; requested $version"

git fetch origin main --tags --force
main_sha="$(git rev-parse origin/main)"
head_sha="$(git rev-parse HEAD)"
[[ "$target_sha" == "$main_sha" && "$target_sha" == "$head_sha" ]] \
    || die "target SHA must equal checked-out latest main ($head_sha / $main_sha)"

transaction_root="${RUNNER_TEMP:-${TMPDIR:-/tmp}}"
transaction_dir="$(mktemp -d "${transaction_root%/}/balancebar-rebuild.XXXXXX")"
backup_dir="$transaction_dir/backup"
mkdir -p "$backup_dir"
release_before="$transaction_dir/release-before.json"
release_after="$transaction_dir/release-after.json"
replacement_asset="$transaction_dir/$asset_name"
cp "$replacement_dmg" "$replacement_asset"

cleanup() {
    rm -rf -- "$transaction_dir"
}
trap cleanup EXIT

gh release view "$tag" \
    --repo "$repository" \
    --json databaseId,name,body,isDraft,isPrerelease,assets \
    > "$release_before"

original_asset_count="$(jq '.assets | length' "$release_before")"
notes_manifest_name="BalanceBar-release-notes-${version}-manifest.json"
notes_locales=()
while IFS= read -r locale
do
    notes_locales+=("$locale")
done < <(node --input-type=module -e 'import { RELEASE_NOTES_LOCALES } from "./scripts/release/render-release-notes.mjs"; for (const locale of RELEASE_NOTES_LOCALES) console.log(locale)')
expected_notes_assets=("$notes_manifest_name")
for locale in "${notes_locales[@]}"
do
    expected_notes_assets+=("BalanceBar-release-notes-${version}-${locale}.md")
done

original_asset_names_json="$(jq -c '[.assets[].name] | sort' "$release_before")"
expected_legacy_assets_json="$(jq -cn --arg dmg "$asset_name" '[ $dmg ]')"
expected_notes_assets_json="$(printf '%s\n' "$asset_name" "${expected_notes_assets[@]}" | jq -R -s 'split("\n") | map(select(length > 0)) | sort')"
if [[ "$original_asset_names_json" == "$expected_legacy_assets_json" ]]; then
    release_inventory="legacy"
elif [[ "$original_asset_names_json" == "$expected_notes_assets_json" ]]; then
    release_inventory="multilingual-notes"
else
    die "Release $tag must contain the expected DMG-only or multilingual notes inventory"
fi

while IFS= read -r original_asset
do
    gh release download "$tag" \
        --repo "$repository" \
        --pattern "$original_asset" \
        --dir "$backup_dir"
done < <(jq -r '.assets[].name' "$release_before")
backup_asset="$backup_dir/$asset_name"
[[ -f "$backup_asset" ]] || die "could not back up existing $asset_name"

old_tag_sha="$(git rev-list -n 1 "$tag")"
[[ "$old_tag_sha" =~ ^[0-9a-f]{40}$ ]] || die "could not resolve existing $tag"

tag_mutation_started=false
asset_mutation_started=false
rollback() {
    local status=$?
    trap - ERR INT TERM
    if [[ "$tag_mutation_started" == "true" ]]; then
        printf 'rebuild-existing-release: replacement failed; restoring tag\n' >&2
        git tag -fa "$tag" "$old_tag_sha" -m "BalanceBar ${version} rollback" || true
        git push --force origin "refs/tags/$tag" || true
    fi
    if [[ "$asset_mutation_started" == "true" ]]; then
        printf 'rebuild-existing-release: replacement failed; restoring DMG\n' >&2
        gh release upload "$tag" "$backup_asset" --repo "$repository" --clobber || true
    fi
    exit "$status"
}
trap rollback ERR INT TERM

tag_mutation_started=true
git tag -fa "$tag" "$target_sha" -m "BalanceBar ${version} rebuilt"
git push --force origin "refs/tags/$tag"
asset_mutation_started=true
gh release upload "$tag" "$replacement_asset" --repo "$repository" --clobber

gh release view "$tag" \
    --repo "$repository" \
    --json databaseId,name,body,isDraft,isPrerelease,assets \
    > "$release_after"

before_metadata="$(jq -Sc '{databaseId,name,body,isDraft,isPrerelease}' "$release_before")"
after_metadata="$(jq -Sc '{databaseId,name,body,isDraft,isPrerelease}' "$release_after")"
[[ "$before_metadata" == "$after_metadata" ]] \
    || die "Release metadata changed while replacing the DMG"

final_asset_count="$(jq '.assets | length' "$release_after")"
final_asset_names_json="$(jq -c '[.assets[].name] | sort' "$release_after")"
if [[ "$release_inventory" == "legacy" ]]; then
    [[ "$final_asset_count" -eq 1 && "$final_asset_names_json" == "$expected_legacy_assets_json" ]] \
        || die "Release $tag must contain only $asset_name after rebuilding"
else
    [[ "$final_asset_names_json" == "$expected_notes_assets_json" ]] \
        || die "Release $tag lost or changed its multilingual notes inventory after rebuilding"
    original_notes_inventory="$(jq -Sc --arg dmg "$asset_name" '[.assets[] | select(.name != $dmg) | {name,size,digest}] | sort_by(.name)' "$release_before")"
    final_notes_inventory="$(jq -Sc --arg dmg "$asset_name" '[.assets[] | select(.name != $dmg) | {name,size,digest}] | sort_by(.name)' "$release_after")"
    [[ "$original_notes_inventory" == "$final_notes_inventory" ]] \
        || die "Release $tag multilingual notes size/digest inventory changed while rebuilding"
fi

remote_tag_sha="$(git ls-remote origin "refs/tags/${tag}^{}" | awk 'NR == 1 { print $1 }')"
[[ "$remote_tag_sha" == "$target_sha" ]] \
    || die "remote $tag points to $remote_tag_sha instead of $target_sha"

tag_mutation_started=false
asset_mutation_started=false
trap - ERR INT TERM
printf 'rebuild-existing-release: rebuilt %s at %s with only %s\n' \
    "$tag" "$target_sha" "$asset_name"
