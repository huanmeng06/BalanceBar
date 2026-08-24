#!/usr/bin/env bash

set -Eeuo pipefail

source_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
release_root="$source_dir/release-notes"
bundle_root="${1:-}"

die() {
    printf 'release-notes-resource-probe: error: %s\n' "$*" >&2
    exit 1
}

validate_root() {
    local root="$1"
    python3 - "$root" <<'PY'
import json
import pathlib
import re
import sys

root = pathlib.Path(sys.argv[1]).resolve()
manifest_path = root / "manifest.json"
if not manifest_path.is_file():
    raise SystemExit(f"manifest is missing: {manifest_path}")

manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
if manifest.get("schemaVersion") != 1:
    raise SystemExit("manifest schemaVersion must be 1")
releases = manifest.get("releases")
if not isinstance(releases, dict) or not releases:
    raise SystemExit("manifest releases must be a non-empty object")

required_locales = {
    "en", "zh-Hans", "zh-Hant-TW", "zh-Hant-HK",
    "ja", "ko", "es", "de",
}
version_pattern = re.compile(r"^[0-9]+\.[0-9]+\.[0-9]+(?:-[0-9A-Za-z.-]+)?$")

for version, entry in releases.items():
    if not version_pattern.fullmatch(version):
        raise SystemExit(f"invalid release version key: {version}")
    files = entry.get("files") if isinstance(entry, dict) else None
    if not isinstance(files, dict) or not required_locales.issubset(files):
        raise SystemExit(f"{version} must provide all eight language files")
    for locale in required_locales:
        relative = files[locale]
        if not isinstance(relative, str) or not relative.endswith(".md"):
            raise SystemExit(f"{version}/{locale} must point to a Markdown file")
        relative_path = pathlib.PurePosixPath(relative)
        if relative_path.is_absolute() or ".." in relative_path.parts:
            raise SystemExit(f"unsafe Markdown path for {version}/{locale}")
        note_path = (root / relative).resolve()
        if root not in note_path.parents or not note_path.is_file():
            raise SystemExit(f"Markdown file is missing: {note_path}")
        if not note_path.read_text(encoding="utf-8").strip():
            raise SystemExit(f"Markdown file is empty: {note_path}")

print(f"validated {len(releases)} release(s) and eight locales")
PY
}

[[ -d "$release_root" ]] || die "source release-notes directory is missing: $release_root"
validate_root "$release_root"

if [[ -n "$bundle_root" ]]; then
    packaged_root="$bundle_root/Contents/Resources/release-notes"
    [[ -d "$packaged_root" ]] || die "packaged release-notes directory is missing: $packaged_root"
    validate_root "$packaged_root"
    printf 'release-notes-resource-probe: PASS (source and bundle=%s)\n' "$bundle_root"
else
    printf 'release-notes-resource-probe: PASS (source)\n'
fi
