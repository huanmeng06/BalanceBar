#!/usr/bin/env bash
# Builds a merged-PR event for a manually selected PR so Release jobs can run
# the normal pipeline. Exports MERGE_SHA and RELEASE_EVENT_PATH via GITHUB_ENV.
set -Eeuo pipefail
source_pr="${1:?usage: prepare-manual-event.sh <merged PR number>}"
pr_json="$(gh pr view "$source_pr" \
  --repo "$GITHUB_REPOSITORY" \
  --json number,title,body,url,state,mergedAt,mergeCommit,labels,closingIssuesReferences)"
state="$(jq -r '.state' <<< "$pr_json")"
[[ "$state" == "MERGED" ]] \
  || { echo "PR #$source_pr is not merged (state: $state)." >&2; exit 1; }

merge_sha="$(jq -r '.mergeCommit.oid // empty' <<< "$pr_json")"
[[ "$merge_sha" =~ ^[0-9a-f]{40}$ ]] \
  || { echo "PR #$source_pr has no valid merge commit." >&2; exit 1; }
echo "MERGE_SHA=$merge_sha" >> "$GITHUB_ENV"

manual_event="$RUNNER_TEMP/balancebar-manual-event.json"
jq --arg merge_sha "$merge_sha" '{
  pull_request: {
    number,
    title,
    body,
    html_url: .url,
    merged: true,
    merge_commit_sha: $merge_sha,
    labels,
    closingIssuesReferences
  }
}' <<< "$pr_json" > "$manual_event"
echo "RELEASE_EVENT_PATH=$manual_event" >> "$GITHUB_ENV"
