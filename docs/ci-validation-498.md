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
unrelated files, mode changes, invalid/deleted/renamed plists and missing revisions. Policy fixtures cover
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

## Hosted transition / cancellation evidence

- Draft push [38350686906](https://github.com/huanmeng06/BalanceBar/actions/runs/38350686906): gate created alongside scope and failed for Draft, then superseded by Ready.
- Draft → Ready [38350701184](https://github.com/huanmeng06/BalanceBar/actions/runs/38350701184): gate in progress while Full ran. Explicitly cancelled Full; Full conclusion `cancelled`, gate `failure`, no passing credential.
- Ready → Draft [38350776560](https://github.com/huanmeng06/BalanceBar/actions/runs/38350776560): same head `232b9bb0f93523e95ed81f791a3978afb1da5bee`, gate `failure`, Full `skipped`, Fast resumed.
- Explicit dispatch [38350701721](https://github.com/huanmeng06/BalanceBar/actions/runs/38350701721): Full started, Fast/version skipped, independent `Manual Full result` remained in progress while PR state switched back to Draft. Dispatch was not cancelled by PR event concurrency and subsequently **succeeded**. Latest Ready/synchronize results are recorded in the PR handoff.

### Remaining measurement limits

This Issue's sole PR changes CI scripts/configuration, so its effective PR-wide
diff is never documentation-only or pure-version-only. Testing those hosted
paths in this PR would require discarding this implementation or creating an
extra PR. They are validated by local classifier/scope fixtures; isolated hosted
Swift-only, test-only and docs/version-only performance comparisons remain an
Owner follow-up after integration. No three-scenario performance result is
claimed. The baseline did not record separate CLI/probe/Xcode timers; this change
adds them for future reproducible comparisons. Required-check enforcement is
still **not activated**; same-context latest-check selection must be confirmed
in Owner acceptance after safe ruleset activation.


## Completed hosted Full (explicit dispatch)

Run [38350701721](https://github.com/huanmeng06/BalanceBar/actions/runs/38350701721)
at head `232b9bb0f93523e95ed81f791a3978afb1da5bee`: **success**, including
scope, Full, artifact upload, macos-15 smoke and independent Manual Full result.
Total workflow wall time **7m54s**; initial Ubuntu runner wait **4s**; Full began
7s after scope completed. Full job **7m11s**, environment setup/checkout/SDK
verification **2/3/2s**, independent checks **80s** (CLI **79s**, standalone probes
**22s**, Xcode **75s**, running concurrently), XCTest **5m31s**, counts extraction
**3s**, artifact stage/upload **0/2s** at timestamp resolution, smoke **11s**
(download **2s**, non-GUI verification **2s**). Gate polling added approximately
6s after smoke completion. These are measured timestamps, not estimates.

XCTest: **1320 total / 1307 passed / 0 failed / 13 skipped**. One existing skip
requires a pre-macOS-26 environment; 12 animation tests skip for hosted runner
Reduce Motion. No skipped tests are claimed to have passed. Test sources,
parallelizable=NO and Release/Forward SDK workflows remain unchanged.

Ready → Draft → Ready and subsequent Ready push generated runs
[38350899716](https://github.com/huanmeng06/BalanceBar/actions/runs/38350899716)
and [38350907180](https://github.com/huanmeng06/BalanceBar/actions/runs/38350907180).
Closing/reopening this same Ready PR generated
[38351111508](https://github.com/huanmeng06/BalanceBar/actions/runs/38351111508),
then a further Ready code/configuration push generated
[38351297734](https://github.com/huanmeng06/BalanceBar/actions/runs/38351297734).
Superseded runs were cancelled by PR concurrency; no success is claimed for
those runs. Temporary unmerged close produced only a skipped Release
[38351108308](https://github.com/huanmeng06/BalanceBar/actions/runs/38351108308),
no publication. The final evidence-only documentation commit will also require
Full because classification considers the **entire PR**, not its last commit.
Final latest-head result, SHA, full counts and artifact are in the PR/Issue handoff.


## PR #499 Request Changes rework

Review baseline: `bd7486473e1971964c09578e17a69fd4b2f87cf5`.
BLOCK 2 adds target-branch `edited` routing and base-ref identity; title/body
edits have an isolated no-credential check and concurrency group. BLOCK 3 only
carries the latest successful same-run/head scope, with current-attempt Full and
smoke plus 60-second missing-job diagnostics. Artifacts are attempt-named.

Reproducible policy tests use a fake clock for scope reuse, latest failure vs
older success, foreign run/head, ref changes at identical SHA, genuine queued
prerequisites, missing Full/smoke and forced Full on retarget. Real queued jobs
can wait; unsupported partial reruns do not wait 23 minutes. Final hosted
retarget/metadata/partial-rerun evidence is maintained in the PR/Issue handoff.

BLOCK 1 remains an Owner activation/merge-blocking acceptance step after workflow
integration and safe migration of open PRs. It is not a Swift fix and is not
claimed completed. Performance risks (test-target compilation and full-history
fetch) are recorded only; no target split or history optimization is included.


Hosted discovery during rework: Re-run failed jobs copied successful scope into
attempt 2 under a new job ID but kept its attempt-1 start/end timestamps.
Therefore `run_attempt` alone cannot prove execution freshness. The gate now
requires Full/version/smoke execution timestamps within the current attempt;
carried scope is resolved to its original successful execution for provenance.
A regression reproduces copied successful Full/smoke with new attempt IDs and
verifies that they are rejected, while copied scope plus genuinely fresh Full
and smoke succeeds. Final hosted evidence is in the PR/Issue handoff.


### Hosted rework trigger and partial-rerun evidence

- Ready retarget to existing `codex/issue-491`:
  [38362414553](https://github.com/huanmeng06/BalanceBar/actions/runs/38362414553)
  selected Full, not metadata/version exemption. Full failed in an explicitly
  temporary first-attempt fixture; gate failed. No app-test regression is claimed.
- Draft retarget back to main:
  [38362625561](https://github.com/huanmeng06/BalanceBar/actions/runs/38362625561)
  selected Fast, Full skipped, gate failure. Fast was superseded when made Ready.
  The existing target branch was not modified and PR base is restored to main.
- Title/body edited during Full:
  [38363236670](https://github.com/huanmeng06/BalanceBar/actions/runs/38363236670)
  and corrected-head
  [38384664204](https://github.com/huanmeng06/BalanceBar/actions/runs/38384664204)
  ran only successful metadata acknowledgement (validation jobs skipped), with
  **no PR merge gate** check. Parent Full continued; these are not merge credentials.
- Corrected-head failed-jobs rerun:
  [38363884002 attempt 2](https://github.com/huanmeng06/BalanceBar/actions/runs/38363884002/attempts/2)
  succeeded at `ecf67494550ce77fae6ee8e1f9908b1e76a81c2f`.
  Summary explicitly reports `scope_reused: True`, scope job `115184423863`
  from attempt 1, fresh Full job `115252506036` and smoke `115255920134` from
  attempt 2. Artifact `BalanceBar-macos26-sdk-attempt-2` (ID `11806460204`)
  was verified present/unexpired with the same head.

Partial-rerun XCTest: **1320 total /1307 passed /0 failed /13 existing skips**.
Attempt-2 wall time **9m24s**, Full job **8m53s**, independent checks **103s**
(CLI **101s**, standalone probes **19s**, Xcode **87s** concurrently), XCTest
**6m49s**, counts **4s**, stage/upload **1/2s**, smoke **10s**. Carried scope's
old 6-second execution was not rerun. Copied skipped jobs even had old completion
and newer start timestamps; do not calculate execution cost from such projections.

The temporary failure fixture has been removed from the delivery workflow.
Gate-only rerun rejection and the final fixture-free SHA's Full result are in the
PR/Issue handoff. These experiments do not activate repository required checks.

Gate-only re-run of the successful partial cycle,
[38363884002 attempt 3](https://github.com/huanmeng06/BalanceBar/actions/runs/38363884002/attempts/3),
failed as intended. GitHub projected old successful Full/smoke into attempt 3,
but their execution timestamps predated its start. Gate summary had fresh Full
`missing`, scope reused from original attempt 1, and `Re-run all jobs` guidance.
The evidence step took **63 seconds** (60-second missing-evidence grace plus API
startup), not 23 minutes. The final diagnostic explicitly says “Missing fresh
current-attempt evidence” to distinguish copied job projections from execution.
No prior Full/smoke credential was borrowed. The final fixture-free commit is
verified separately, so this intentional failure is not the delivery CI result.
