#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
build_dir="$repo_root/build/automatic-update-test"
mode="${1:-quit}"
case "$mode" in
    quit|idle|tampered|read-only) ;;
    clean)
        shopt -s nullglob
        runs=("$build_dir"/run.*/)
        for run in "${runs[@]}"; do
            [[ -f "$run/bundle-id" ]] || continue
            bundle_id="$(<"$run/bundle-id")"
            [[ "$bundle_id" =~ ^com\.huanmeng06\.BalanceBar\.dev\.update-test\.[A-F0-9-]{36}$ ]] || exit 1
            support="$HOME/Library/Application Support/$bundle_id"
            if /bin/ps -axo command= | /usr/bin/awk -v app="${run%/}/" -v updater="$support/Updater/" '
                index($0, app) == 1 || index($0, updater) == 1 { found=1 }
                END { exit !found }
            '; then
                printf 'Quit the test app and wait for its updater before cleaning: %s\n' "$run" >&2
                exit 1
            fi
        done
        for run in "${runs[@]}"; do
            [[ -f "$run/bundle-id" ]] || continue
            bundle_id="$(<"$run/bundle-id")"
            /usr/bin/defaults delete "$bundle_id" 2>/dev/null || true
            chmod u+w "$run/install" 2>/dev/null || true
            rm -rf -- "$HOME/Library/Application Support/$bundle_id" "$run"
        done
        exit 0
        ;;
    *)
        printf 'Usage: %s [quit|idle|tampered|read-only|clean]\n' "$0" >&2
        exit 2
        ;;
esac
mkdir -p "$build_dir"
test_dir="$(mktemp -d "$build_dir/run.XXXXXXXX")"
bundle_id="com.huanmeng06.BalanceBar.dev.update-test.$(/usr/bin/uuidgen)"
current_version="90.0.0"
update_version="90.1.0"
asset_dir="$test_dir/assets"
test_app="$test_dir/install/BalanceBar Update Test.app"
payload_app="$test_dir/payload/BalanceBar.app"
dmg_path="$asset_dir/BalanceBar-$update_version.dmg"
mkdir -p "$asset_dir" "$test_dir/payload" "$test_dir/install"
printf '%s\n' "$bundle_id" > "$test_dir/bundle-id"

printf 'Building the test app...\n'
if ! xcodebuild -project "$repo_root/BalanceBar.xcodeproj" -scheme BalanceBar \
    -configuration Debug -destination 'platform=macOS' \
    -derivedDataPath "$build_dir/DerivedData" CODE_SIGNING_ALLOWED=NO \
    COMPILER_INDEX_STORE_ENABLE=NO build > "$test_dir/build.log" 2>&1; then
    tail -n 40 "$test_dir/build.log" >&2
    printf 'Build log: %s\n' "$test_dir/build.log" >&2
    exit 1
fi
built_app="$build_dir/DerivedData/Build/Products/Debug/BalanceBar.app"

prepare_app() {
    local app="$1" version="$2"
    /usr/bin/ditto "$built_app" "$app"
    local plist="$app/Contents/Info.plist"
    /usr/bin/plutil -replace CFBundleIdentifier -string "$bundle_id" "$plist"
    /usr/bin/plutil -replace CFBundleShortVersionString -string "$version" "$plist"
    /usr/bin/plutil -replace Label -string "$bundle_id.chatgpt-launch-agent" \
        "$app/Contents/Library/LaunchAgents/balancebar-chatgpt-launch-agent.plist"
    /usr/bin/codesign --force --deep --sign - "$app"
    /usr/bin/codesign --verify --deep --strict "$app"
}
prepare_app "$test_app" "$current_version"
prepare_app "$payload_app" "$update_version"

printf 'Creating the signed update fixture...\n'
/usr/bin/hdiutil create -quiet -srcfolder "$test_dir/payload" \
    -volname "BalanceBar Update Test" -format UDZO "$dmg_path"
commit="$(git -C "$repo_root" rev-parse HEAD)"
public_key="$(/usr/bin/swift -module-cache-path "$build_dir/SwiftModuleCache" - \
    "$dmg_path" "$bundle_id" "$update_version" "$commit" "$mode" <<'SWIFT'
import CryptoKit
import Foundation

let dmg = URL(fileURLWithPath: CommandLine.arguments[1])
let bundleIdentifier = CommandLine.arguments[2]
let version = CommandLine.arguments[3]
let commit = CommandLine.arguments[4]
let tampered = CommandLine.arguments[5] == "tampered"
let tag = "v" + version
let assetDirectory = dmg.deletingLastPathComponent()
let manifest = dmg.deletingPathExtension().appendingPathExtension("update.json")
let signature = manifest.appendingPathExtension("sig")
let bytes = try Data(contentsOf: dmg, options: .mappedIfSafe)
let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()

func writeJSON(_ object: [String: Any], to url: URL) throws -> Data {
    let data = try JSONSerialization.data(withJSONObject: object, options: .sortedKeys)
    try data.write(to: url)
    return data
}

let manifestBytes = try writeJSON([
    "schema": 1, "bundleIdentifier": bundleIdentifier, "version": version,
    "channel": "stable", "tag": tag,
    "asset": ["name": dmg.lastPathComponent, "size": bytes.count, "sha256": digest],
    "source": ["repository": "huanmeng06/BalanceBar", "commit": commit, "runId": "1", "runAttempt": "1"],
    "signedAt": ISO8601DateFormatter().string(from: Date())
], to: manifest)
let key = Curve25519.Signing.PrivateKey()
var signedBytes = try key.signature(for: manifestBytes)
if tampered { signedBytes[0] ^= 1 }
let signatureBytes = try writeJSON([
    "schema": 1, "algorithm": "ed25519", "keyId": "dev-test",
    "signature": signedBytes.base64EncodedString()
], to: signature)

let assets = [(dmg, bytes.count), (manifest, manifestBytes.count), (signature, signatureBytes.count)]
_ = try writeJSON([
    "tag_name": tag, "draft": false, "prerelease": false,
    "body": "Local automatic-update test release.",
    "assets": assets.map { url, size in
        [
            "name": url.lastPathComponent, "size": size,
            "browser_download_url": "https://github.com/huanmeng06/BalanceBar/releases/download/\(tag)/\(url.lastPathComponent)"
        ] as [String: Any]
    }
], to: assetDirectory.appendingPathComponent("release.json"))
print(key.publicKey.rawRepresentation.base64EncodedString())
SWIFT
)"

# A fresh preference domain keeps the test on Stable with the Dashboard open.
/usr/bin/defaults write "$bundle_id" didMigrateToBalanceBarApp.v1 -bool YES
launch_environment=(
    "BALANCEBAR_RELEASE_FIXTURE_PATH=$asset_dir/release.json"
    "BALANCEBAR_UPDATE_ASSET_DIRECTORY=$asset_dir"
    "BALANCEBAR_UPDATE_TEST_PUBLIC_KEY=$public_key"
)
if [[ "$mode" == idle || "$mode" == read-only ]]; then
    launch_environment+=("BALANCEBAR_UPDATE_IDLE_SECONDS=30")
fi
open_args=()
test_plist="$test_app/Contents/Info.plist"
/usr/bin/plutil -insert LSEnvironment -xml '<dict/>' "$test_plist"
for variable in "${launch_environment[@]}"; do
    /usr/bin/plutil -insert "LSEnvironment.${variable%%=*}" -string "${variable#*=}" "$test_plist"
    open_args+=(--env "$variable")
done
/usr/bin/codesign --force --deep --sign - "$test_app"
/usr/bin/codesign --verify --deep --strict "$test_app"
if [[ "$mode" == read-only ]]; then
    chmod a-w "$test_dir/install"
fi
/usr/bin/open -R "$test_app"
/usr/bin/open -a "$test_app" "${open_args[@]}"
printf '\nTest app: %s\nExpected update: %s -> %s\n' "$test_app" "$current_version" "$update_version"
