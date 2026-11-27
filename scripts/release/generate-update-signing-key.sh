#!/usr/bin/env bash

set -Eeuo pipefail

die() {
    printf 'generate-update-signing-key: %s\n' "$*" >&2
    exit 1
}

[[ $# -ge 1 && $# -le 2 ]] || die "usage: $0 /path/outside/repository/private-key.pem [key-id]"
key_path="$1"
key_id="${2:-bb-release-1}"
[[ "$key_id" =~ ^[A-Za-z0-9._-]+$ ]] || die "invalid keyId: $key_id"

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
key_parent="$(cd "$(dirname "$key_path")" && pwd -P)" || die "key directory does not exist"
key_path="$key_parent/$(basename "$key_path")"
[[ "$key_path" != "$repo_root"/* ]] || die "private key path must be outside the repository"
[[ ! -e "$key_path" ]] || die "refusing to overwrite existing file: $key_path"

openssl_version="$(openssl version | awk '{print $2}')"
openssl_major="${openssl_version%%.*}"
[[ "$openssl_major" =~ ^[0-9]+$ && "$openssl_major" -ge 3 ]] \
    || die "OpenSSL 3 or newer is required"

umask 077
openssl genpkey -algorithm ED25519 -out "$key_path"
chmod 600 "$key_path"
public_der="$(openssl pkey -in "$key_path" -pubout -outform DER | tail -c 32 | base64 | tr -d '\n')"
[[ "${#public_der}" -eq 44 ]] || die "could not extract the Ed25519 public key"

printf 'keyId: %s\n' "$key_id"
printf 'publicKey: %s\n' "$public_der"
printf '\nAdd this dictionary to Resources/Info.plist under BalanceBarUpdateSigningKeys:\n'
cat <<EOF
<dict>
    <key>keyId</key>
    <string>$key_id</string>
    <key>publicKey</key>
    <string>$public_der</string>
</dict>
EOF
printf '\nSet the repository Actions secret with:\n'
printf 'gh secret set BALANCEBAR_UPDATE_SIGNING_KEY --repo huanmeng06/BalanceBar < %q\n' "$key_path"
printf '\nBack up the private key offline, then remove the local file: %q\n' "$key_path"
