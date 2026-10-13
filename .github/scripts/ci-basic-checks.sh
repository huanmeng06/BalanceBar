#!/usr/bin/env bash
set -Eeuo pipefail
# Scope checkout has full history. Manual dispatch checks its current commit.
base="${1:-HEAD^}"
git diff --check "$base" HEAD
while IFS= read -r -d '' script; do bash -n "$script"; done < <(git ls-files -z '*.sh')
python3 .github/scripts/ci-policy-test.py
bash .github/scripts/classify-version-only-diff-test.sh
# actionlint validates expressions, needs references and workflow syntax.
# Pin the release and verify its published checksum before running.
version=1.7.7
archive="actionlint_${version}_linux_amd64.tar.gz"
curl --fail --silent --show-error --location "https://github.com/rhysd/actionlint/releases/download/v${version}/${archive}" -o "$RUNNER_TEMP/$archive"
curl --fail --silent --show-error --location "https://github.com/rhysd/actionlint/releases/download/v${version}/actionlint_${version}_checksums.txt" -o "$RUNNER_TEMP/actionlint-checksums.txt"
(cd "$RUNNER_TEMP"; grep " $archive\$" actionlint-checksums.txt | sha256sum -c -)
tar -xzf "$RUNNER_TEMP/$archive" -C "$RUNNER_TEMP" actionlint
"$RUNNER_TEMP/actionlint" -shellcheck= -ignore 'label "macos-26" is unknown'
