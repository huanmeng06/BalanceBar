#!/usr/bin/env bash
# Usage: ci-xctest-shard.sh <shard> <products-dir> <result-bundle>
# Runs one serial XCTest shard from build-for-testing products. The final
# shard skips every listed class, so the shards always cover the full bundle.
set -Eeuo pipefail
shard="$1" products="$2" result="$3"
plan="$(dirname "$0")/../ci-test-shards.txt"
last=$(( $(awk '!/^#/ && NF { print $1 }' "$plan" | sort -n | tail -1) + 1 ))
(( shard >= 1 && shard <= last )) || { echo "shard $shard outside 1..$last" >&2; exit 1; }
selection=()
while read -r index class; do
  [[ -z "$index" || "$index" == \#* ]] && continue
  if (( shard == last )); then
    selection+=("-skip-testing:BalanceBarTests/$class")
  elif (( index == shard )); then
    selection+=("-only-testing:BalanceBarTests/$class")
  fi
done < "$plan"
(( ${#selection[@]} > 0 )) || { echo "shard $shard selects nothing" >&2; exit 1; }
xctestrun=("$products"/*.xctestrun)
[[ ${#xctestrun[@]} == 1 && -f "${xctestrun[0]}" ]] || { echo "expected one xctestrun in $products" >&2; exit 1; }
echo "XCTest shard $shard/$last: ${selection[*]}"
xcodebuild test-without-building -xctestrun "${xctestrun[0]}" \
  -destination 'platform=macOS,arch=arm64' -parallel-testing-enabled NO \
  -retry-tests-on-failure -test-iterations 2 \
  -resultBundlePath "$result" "${selection[@]}"
