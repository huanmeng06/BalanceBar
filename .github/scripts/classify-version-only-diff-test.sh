#!/usr/bin/env bash

set -Eeuo pipefail

script_dir="$(cd -- "$(dirname -- "$0")" && pwd)"
classifier="$script_dir/classify-version-only-diff.sh"
test_root="$(mktemp -d)"
trap 'rm -rf "$test_root"' EXIT

assert_classification() {
    local expected="$1"
    local actual
    actual="$(cd "$test_root" && "$classifier" "$base" HEAD)"
    if [[ "$actual" != "$expected" ]]; then
        printf 'expected %s, got %s\n' "$expected" "$actual" >&2
        exit 1
    fi
}

mkdir -p "$test_root/Resources"
cd "$test_root"
git init -q
git config user.email 'ci-classifier-test@example.invalid'
git config user.name 'CI classifier test'

cat > Resources/Info.plist <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key>
  <string>BalanceBar</string>
  <key>CFBundleShortVersionString</key>
  <string>1.2.27</string>
  <key>CFBundleVersion</key>
  <string>70</string>
</dict>
</plist>
PLIST
git add Resources/Info.plist
git commit -q -m 'test fixture base'
base=$(git rev-parse HEAD)

printf '%s\n' 'code change' > Resources/Source.swift
git add Resources/Source.swift
git commit -q -m 'test fixture ordinary code change'
assert_classification full

sed -i.bak \
    -e 's#<string>1.2.27</string>#<string>1.2.28</string>#' \
    -e 's#<string>70</string>#<string>71</string>#' \
    Resources/Info.plist
git add Resources/Info.plist
git commit -q -m 'test fixture pure version bump'
assert_classification full
# Same head is pure version-only relative to the code commit, never the PR base.
actual="$("$classifier" HEAD^ HEAD)"
[[ "$actual" == version-only ]]
[[ "$("$classifier" HEAD)" == version-only ]]

sed -i.bak \
    -e 's#<string>BalanceBar</string>#<string>BalanceBar altered</string>#' \
    Resources/Info.plist
git add Resources/Info.plist
git commit -q -m 'test fixture version bump with non-version plist change'
assert_classification full

sed -i.bak \
    -e 's#<string>1.2.28</string>#<string>1.2.29</string>#' \
    -e 's#<string>71</string>#<string>72</string>#' \
    Resources/Info.plist
printf '%s\n' 'unrelated change' > Resources/Unexpected.swift
git add Resources/Info.plist Resources/Unexpected.swift
git commit -q -m 'chore: bump version with unrelated file'
assert_classification full

git reset --hard -q "$base"
sed -i.bak -e 's#<string>1.2.27</string>#<string>1.2.28</string>#' -e 's#<string>70</string>#<string>71</string>#' Resources/Info.plist
git add Resources/Info.plist
git commit -q -m 'true pure version PR'
assert_classification version-only
chmod +x Resources/Info.plist
git add Resources/Info.plist
git commit -q -m 'mode change is not a version exemption'
assert_classification full
[[ "$("$classifier" nonexistent HEAD)" == full ]]
git reset --hard -q "$base"
printf '%s\n' '<not-a-plist>' > Resources/Info.plist
git add Resources/Info.plist
git commit -q -m 'invalid plist'
assert_classification full
git reset --hard -q "$base"
git mv Resources/Info.plist Resources/Renamed.plist
git commit -q -m 'renamed plist'
assert_classification full
git reset --hard -q "$base"
git rm -q Resources/Info.plist
git commit -q -m 'deleted plist'
assert_classification full
printf '%s\n' 'PR-wide and legacy classifier paths passed'
