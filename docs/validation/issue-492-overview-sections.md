# Issue #492 / PR #495 — independent overview sections

## Contract and implementation

- Reuses `codex/issue-492-overview-sections`, the original worktree and PR #495.
- All cards intentionally retain the user-approved 16pt horizontal inset.
- Account, 5-hour, 7-day, other quota, Luna Reserve, probability and banked-reset sections have separate IDs and local content geometry.
- The card composes visible section heights and adjacent spacing; compatibility card frames are exported from that composition. There is no aggregate quota envelope crossing Reserve.
- The scalar quota compatibility profile also exposes a real row and account header. A header remains visible without an email.
- Header/body spacing is 11pt, quota-family spacing 12pt, quota/reset spacing 22pt, probability/reset-card spacing 16pt, ticket spacing 8pt. No hidden or trailing spacing is inserted.
- Ticket rows always use document coordinates. Parent section metadata contains the summary and viewport, never the offscreen document rows. Eight expanded tickets measure 824pt of document content and a 256pt viewport.
- Official controls are rendered inside section views using local frames; root hosting, link event forwarding and wheel forwarding remain on one `NSMenuItem.view`.
- Value refreshes retain controls. Geometry/topology changes reconcile by section ID, retain unaffected sections, and preserve ticket scroll position. Overflowing title updates can replace a plain label with a marquee without replacing the document.
- Compact/expanded selection considers only the window-description/countdown pair that shares a line. Title and expiry independently use the full text width. Real fonts and Chinese, English, Spanish, German and French copy are covered.
- Menu visibility and clip bounds gate marquee work. Offscreen views suspend animations and invalidate periodic sampling, then resume their phase when visible. Closed menus have no active marquee sampling timers.
- Numeric animations, real countdown baselines, unified 48h subtitle updates, ticket padding, 72/96pt heights and disabled outlines remain in place. No version bump or merge.

## Automated verification

Full XCTest command:

```sh
xcodebuild test -project BalanceBar.xcodeproj -scheme BalanceBar \
  -configuration Debug -derivedDataPath /private/tmp/BalanceBar-sections \
  -destination 'platform=macOS,arch=arm64' CODE_SIGNING_ALLOWED=NO \
  -parallel-testing-enabled NO -testLanguage en
```

- Full local rerun: **1338 tests, 1 skipped, 0 failures**.
- Final targeted run after the title-overflow update: **67 tests, 0 failures** (`OpenCodexCardLayoutTests` and `DashboardProductionPathRegressionTests`).
- The first full run had one failure in untouched `ProviderRefreshCoordinatorTests.testNotificationRefreshRequestsOnlyEnabledProviders`: its summary semaphore is signaled before the notification callback, so checking the last notification can race. The unmodified test passed in the full rerun. Do not omit that initial failure from the delivery history.
- Initial sandboxed XCTest was blocked by the host-activation script. The actual tests above ran with the required sandbox escalation; these are executed assertions, not compile-only results.
- `./scripts/build.sh dev` and `./scripts/build.sh demo-banked-reset-10` generate isolated bundles with separate Bundle IDs.
- Deployment artifact smoke verifies signatures, load commands and macOS 14 minimum version. Localization resource probe verifies 502 keys across 12 languages.
- Old root-child geometry assertions now recurse and convert to card coordinates before comparing. Existing language-sensitive provider-page fixtures explicitly select English and restore the prior language.

### Ten-long-ticket sampling

Non-interactive AppKit window fixture, 30 overflowing text views, 256pt viewport:

| State | Active sampling timers | Process CPU seconds | Wall seconds |
| --- | ---: | ---: | ---: |
| Open, top | 8 | 0.007887 | 0.251068 |
| Open, bottom | 7 | 0.006104 | 0.250412 |
| Closed | 0 | 0.000648 | 0.250139 |

The fixture checks offscreen suspension, phase restoration, nested scroll hit testing and zero closed-menu timers. These short process samples establish bounded periodic work; they do not replace profiling an actual native menu or manual visual acceptance.

Local logs: `/private/tmp/BalanceBar-sections-full.log` (initial failure), `/private/tmp/BalanceBar-sections-full-rerun.log`, `/private/tmp/BalanceBar-sections-final-targeted.log`, `/private/tmp/BalanceBar-sections-dev.log`, `/private/tmp/BalanceBar-sections-demo10.log`.

## 如何人工测试

开发版：`/Users/huan_meeng/.codex/worktrees/1e06/BalanceBar/build/dev/BalanceBar-dev.app`

十张票券演示版：`/Users/huan_meeng/.codex/worktrees/1e06/BalanceBar/build/demo/banked-reset-10/BalanceBar-BankedReset-10.app`

准备：使用独立开发版或演示版；选择 Codex、详细重置卡模式。语言分别检查中文、英文、西班牙语、德语和法语。

1. 打开菜单，检查账户头部、独立 5h/7d、Reserve、概率和重置卡的对齐与分组间距。无邮箱时 Provider 标题仍存在。
2. 检查票券标题/描述/到期文字：放得下时静止，超宽时滚动。标题与到期文字不被倒计时列额外挤压，描述和倒计时不重叠。普通中英文也允许根据真实宽度进入 96pt 模式。
3. 用十张票券演示版滚动列表，检查两张完整票券与第三张半张的窗口、滚轮转发、上下边缘裁切和渐隐衔接。返回上方时离屏文字能继续滚动。
4. 保持开发版菜单打开并刷新，检查值原位更新，未变化的票券列表不跳回顶部；额度可见性变化时板块重新排列。关闭菜单后检查空闲 CPU。
5. 检查来源链接只在字形范围内响应，并回归普通余额卡及第三方卡片。

避免测试：发布、合并、版本升级和部署；本轮不改变这些流程。

反馈：`PASS`，或 `FAIL + 步骤 + 语言/模式 + 实际/预期 + 截图或录屏`。

**Manual visual status: pending.** Automated checks do not establish pixel-level acceptance or close Issue #492.

## Four-blocker follow-up after `1ac16d08`

The preceding implementation/verification records describe the baseline delivery. This follow-up is limited to the four newly reported blockers:

- Forecast tooltip body uses the original dynamic `.labelColor`, without `withAlphaComponent`. Title, source, disclaimer, fonts and sizing are unchanged; no appearance override is imposed on the popover.
- A native AppKit probe reproduced freezing: the old body color created under Dark Aqua resolved to RGB `(1,1,1)` under both Dark Aqua and Aqua; the unmodified dynamic label color resolved to `(1,1,1)` under Dark Aqua and `(0,0,0)` under Aqua. Alpha values were respectively 0.85 (old) and the native semantic 0.8470588 (dynamic). This is color-resolution evidence, not a screenshot of the actual popover.
- Regression tests cross all creation/display combinations of Aqua, Dark Aqua and their high-contrast variants, then switch the same view repeatedly. All four text colors are resolved under their actual inherited appearance and compared against their semantic roles.
- The probability reuse signature now includes both primary presentation and subtitle type (forecast, official hint, countdown progress, none). Rendering uses the same classifier. Tests exercise hint → progress → hint → progress, retaining the root, unrelated sections, document and scroll position; same-type progress continues updating in place.
- Other quota sections use the same label identity as the numeric system; scalar fallback uses a separate legacy ID. A 80% → B 20% replaces the numeric control; B 20% → B 25% → B 30% keeps the control, updates values and retains its animation plan.
- Error cards use the shared 16pt inset. Detail width is derived from the amount column while retaining the prior 7pt safe gap. Short/multiline, Chinese/English, long URL and account/subscription combinations are measured and checked for containment/non-overlap. The standalone CoreText probe reads the real shared metrics and uses a private temporary module cache.

Checks: targeted XCTest **108 tests, 0 failures**; final full local XCTest **1342 tests, 1 skipped, 0 failures**. Command is the same as above with derived data `/private/tmp/BalanceBar-blockers`. `scripts/probes/error-card-layout-probe.sh` also passes. Dev and 10-ticket demo bundles are rebuilt from this follow-up; exact remote HEAD/CI and preserved artifact paths are supplied in the PR/Issue handoff.

Logs: `/private/tmp/BalanceBar-blockers-targeted.log`, `/private/tmp/BalanceBar-blockers-full.log`, `/private/tmp/BalanceBar-blockers-color-probe.log`, `/private/tmp/BalanceBar-blockers-error-probe.log`.

Manual re-test: quit the previous development build and restart the new one. Check the official-signal popover in light/dark mode, after an appearance change and on repeated opens; body text must remain readable like the title. Keep the menu open during official-signal refresh and check hint/progress changes without scroll reset. Check a renamed extra quota never shows the previous percentage. Trigger a short/long error and compare its 16pt edges with a normal card. Recheck ordinary 5h/7d animations. This follow-up invalidates prior visual coverage; **manual status remains PENDING**, no version bump or merge.

## Source tooltip refresh follow-up (BLOCK 5)

Same-presentation forecast refresh now updates every configured source link's
structured tooltip and plain hover hint from the latest snapshot. Section and
link identity remain unchanged. Changed content cancels a pending hint and closes
an already displayed bubble; the next hover uses the new content. Equal content
is a no-op, preserving the existing hover timer and bubble during repeated ticks.

Verification: DashboardComponentsTests and DashboardProductionPathRegressionTests
passed (85 tests, zero failures), including same-type timestamp refresh and hint
invalidation. The timestamp regression also covers an official signal changing
83% to 85% without replacing its link. Development packaging, signature/minimum
OS checks and localization resource checks passed (502 keys, 12 languages).
Local full XCTest and interactive GUI acceptance were not repeated for this
bounded change. Draft Fast CI is development feedback, not Full acceptance.

### 如何人工测试

Keep the official Codex menu open, hover the reset probability and note the source
update time. Refresh with a newer timestamp and the same presentation type; the
probability and source hint must both use the latest data. If the bubble was open,
it should close; leave and re-enter the link to inspect the new time. Confirm that
unrelated sections and ticket scrolling retain their position. Deep/light popup
colors and long-text visual acceptance remain manual checks before final Ready
and Full CI acceptance. No version bump or merge is included.
