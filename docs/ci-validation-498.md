# CI #498 validation evidence

This document distinguishes actual hosted runs from local policy fixtures.
Implementation does not change app code or tracked version values.

## Baseline (before changes)

| Run | Workflow wall time | macOS job | Independent builds | XCTest | Stage/upload | Smoke job |
| --- | --- | --- | --- | --- | --- | --- |
| [38340967314](https://github.com/huanmeng06/BalanceBar/actions/runs/38340967314) | 8m35s (Issue observation) | 7m42s | 1m37s | 5m51s | 3s | 10s |
| [38340564558](https://github.com/huanmeng06/BalanceBar/actions/runs/38340564558) | 10m34s (Issue observation) | 10m00s | 2m56s | 6m47s | 3s | 13s |

Source: REST Actions jobs/steps timestamps fetched before implementation. Setup
was 1s in both main jobs; checkout 2s/3s; SDK verification 2s/5s. Baseline grouped
CLI/Xcode/probes in one step without per-process timers, so individual durations
cannot be recovered from timestamps. Remaining workflow wall time includes
runner scheduling, inter-job delays and post-job work; it is not all queue time.
New Full logs each component separately. Step/job timestamps distinguish runner
wait from execution (job `started_at` minus run `created_at` for the initial job;
dependent jobs also wait for prerequisites, so that difference is not queue alone).

## Reproducible local checks

```sh
bash .github/scripts/classify-version-only-diff-test.sh
python3 .github/scripts/ci-policy-test.py
# actionlint 1.7.7; its old runner catalog does not know macos-26
# This ignores only the catalog label diagnostic, not expression/syntax errors.
actionlint -shellcheck= -ignore 'label "macos-26" is unknown'
git diff --check
```

Classifier fixtures cover code → version, true version-only, other plist edits,
unrelated files, mode changes and missing revisions. Policy fixtures cover
Draft/Ready state races, changed head/base, closed PR, scope failures, Full
failure/cancellation/skipped/missing/queued/in-progress, explicit exemption and
dispatch requiring Full. These fixtures prove decision logic, not hosted GitHub
scheduling or required-check activation. Live evidence is appended below.

## Constraints and activation

No main branch protection/rulesets existed at baseline. Required check activation
is deferred to avoid blocking open PR #495 with a context it cannot publish yet.
Owner instructions and unconfigured risk are in `development.md`. No local
installed skills, shared DerivedData, Release/Forward SDK workflows or app version
were modified. No application GUI acceptance is claimed.

## Initial hosted Draft run

[38350310488](https://github.com/huanmeng06/BalanceBar/actions/runs/38350310488),
head `3a47c576c47b246160013862f516d9ee091fb3ad`: scope succeeded;
Fast succeeded in 1m50s, Full/version/smoke skipped, Draft gate deliberately
failed. From run creation (05:13:38Z) to Fast completion (05:15:46Z): **2m08s**;
to gate completion: **2m19s**. Scope runner started after 3s; Fast started 10s
after scope finished. This is a CI/script/documentation change, conservatively
built like an unknown/Swift change, not an isolated Swift-only benchmark.
Relative to baseline workflow wall times, gate feedback was 73%/78% shorter;
this does not establish the same speedup for every change or queue condition.

Check-runs API for head SHA returned all check `head_sha` values equal to that
head; checkout logs showed merge `da527e360eba938afd0b65c3414d264da2c9ecef`
(base `595d113d52e6617a8487da7fc8a8f93c0f30b6bb`). After observing that a
needs-dependent gate only appeared after Fast completion, the gate was changed
to have **no needs** and poll this exact run/attempt, replacing old greens
immediately during same-SHA transitions. Subsequent runs validate this fix.

Local serial `ResponseParsersTests`: 20 total, 20 passed, 0 failed, 0 skipped;
result bundle `/tmp/BalanceBar-Issue498-ResponseParsers.xcresult`. A second run
reusing `/tmp/BalanceBar-Issue498-DerivedData` again passed 20 tests and took
2.77s wall time (`/usr/bin/time -p`), with no full suite requested locally.
