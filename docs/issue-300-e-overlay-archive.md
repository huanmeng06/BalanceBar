# Issue #300 E renderer archive

This document is an engineering handoff for the Core Animation overlay
experiment. E is not the production/default renderer and has no user-facing
renderer switch.

## Archive pointers

- Experiment PR: `#302`
- Experiment branch: `experiment/issue-300-e-overlay`
- E renderer origin: `65d94defc744d10bb8e376f3f7724b94409d97aa`
- E renderer milestones: `c989fe3`, `cd018d6`, and `0716116`
- Latest E lifecycle candidate code head: `8c47a0596b0acab69b0dd1bbb1fe0d8e05d8bab2`

The latest E lifecycle candidate keeps the native bitmap-backed status item
static and presents the rotating Codex icon in a BalanceBar-owned transparent
overlay window. Its current lifecycle experiment binds that overlay to the
real status-item window with public `NSWindow.addChildWindow(_:ordered:)`.
That candidate must remain separate from the native production PR until
multi-display and other manual lifecycle checks are complete.

## Restore / future Beta starting point

To inspect or revive E, use the experiment branch and build with:

```text
BALANCEBAR_EXPERIMENTAL_OVERLAY=1 ./work/balance-bar/build.sh dev
```

The E implementation is intentionally preserved in PR #302 and this branch.
Any future Beta or experimental renderer work should open a separate Issue and
PR from this archive; do not add an E renderer selector or make E the default
as part of the native Issue #300 production fix.
