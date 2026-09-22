#!/usr/bin/env bash

set -Eeuo pipefail

# Isolated compile probe. It is not linked into BalanceBar and does not
# host SwiftUI search inside the AppKit Dashboard.
#
# Question: can public SwiftUI searchToolbarBehavior(.minimize) provide
# Mail-like collapsed search on macOS?
# SDK: SearchToolbarBehavior exists on macOS 26, but `.minimize` is
# `@available(macOS, unavailable)` (iOS 26 / visionOS 26 only).

probe_name="search-toolbar-minimize-poc"
sdk="$(xcrun --sdk macosx --show-sdk-path)"
target="arm64-apple-macosx26.0"
workdir="$(mktemp -d "${TMPDIR:-/tmp}/balancebar-${probe_name}.XXXXXX")"
trap 'rm -rf "$workdir"' EXIT

die() {
    printf '%s: error: %s\n' "$probe_name" "$*" >&2
    exit 1
}

cat >"$workdir/automatic.swift" <<'SWIFT'
import SwiftUI

@available(macOS 26.0, *)
struct AutomaticSearchProbe: View {
    @State private var query = ""

    var body: some View {
        Color.clear
            .frame(width: 640, height: 400)
            .searchable(text: $query)
            .searchToolbarBehavior(.automatic)
    }
}
SWIFT

cat >"$workdir/minimize.swift" <<'SWIFT'
import SwiftUI

@available(macOS 26.0, *)
struct MinimizeSearchProbe: View {
    @State private var query = ""

    var body: some View {
        Color.clear
            .frame(width: 640, height: 400)
            .searchable(text: $query)
            .searchToolbarBehavior(.minimize)
    }
}
SWIFT

typecheck() {
    xcrun --sdk macosx swiftc \
        -target "$target" \
        -sdk "$sdk" \
        -parse-as-library \
        -typecheck \
        "$1"
}

if ! typecheck "$workdir/automatic.swift" >"$workdir/automatic.log" 2>&1; then
    cat "$workdir/automatic.log" >&2
    die "SearchToolbarBehavior.automatic failed to typecheck for macOS 26"
fi

set +e
typecheck "$workdir/minimize.swift" >"$workdir/minimize.log" 2>&1
minimize_status=$?
set -e

if [[ "$minimize_status" -eq 0 ]]; then
    cat "$workdir/minimize.log" >&2
    die "SearchToolbarBehavior.minimize unexpectedly typechecked on macOS"
fi

if ! grep -Fq "'minimize' is unavailable in macOS" "$workdir/minimize.log"; then
    cat "$workdir/minimize.log" >&2
    die "SearchToolbarBehavior.minimize failed for an unexpected reason"
fi

printf '%s\n' \
    "$probe_name: SearchToolbarBehavior.automatic typechecks on macOS 26" \
    "$probe_name: SearchToolbarBehavior.minimize is unavailable on macOS" \
    "$probe_name: Mail-like minimized search is not a public macOS SwiftUI API"
