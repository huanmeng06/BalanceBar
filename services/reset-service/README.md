# Shared reset observation service (MVP)

Data: [codex-reset.com](https://codex-reset.com/), under its
[developer reuse conditions](https://codex-reset.com/developers) and
[terms](https://codex-reset.com/terms). Original posts link to Tibo on X.
This is an independent interpretation of announcement **observation deadlines**,
not evidence that any account's quota reset. No BalanceBar client integration is
included. No X scraping, user credentials, provider database or user quota is read.

## Contract

Expected endpoint after authorized activation:
`https://huanmeng06.github.io/BalanceBar/reset-service/v1/latest.json`.
Confirm the actual Pages URL; it has **not** been deployed or verified by this PR.
`schema.json` is JSON Schema 2020-12; `example.json` is an illustrative historical
replay, **not a live result**. Runtime Python 3.12 uses only the standard library.
Test-only dependencies are pinned in `requirements-dev.txt`.

| Field | Meaning |
| --- | --- |
| `schema_version` | 1; incompatible changes require a new URL/version |
| `status` | `deadline`, `uncertain`, `none`, or `error` |
| `source` | Attribution link, always `https://codex-reset.com/` |
| `generated_at` | UTC run-start time; never refreshed from a cached JSON file |
| `last_verified_at` | Successful source/identity check time; null on error |
| `valid_until` | At most check time + 30 minutes, and never past the deadline |
| `signal` | ID, normalized publication time, original text, source URL, content/context version, available parent, context-completeness flag |
| `observation` | Kind, nullable deadline/evidence/method, diagnostic and timezone policy |

A consumer MUST require `status=deadline`, a recognized schema and method, and
`now < valid_until` and `now < observation.deadline_at`. Treat unknown versions,
invalid JSON or exceeded freshness as unavailable. Do not display `0m` forever.
All non-deadline states have `deadline_at=null`. `approximate_window` currently
preserves only its classification, **no invented numerical range**. Text is
untrusted; render as text, never HTML or commands. A client must show the source
credit with a link on the same surface as the data (a separate credits page is
insufficient). The payload carries the credit for downstream relays.

### Selection and time rules

- Read `/api/forecast` and `/api/feed` once each per run, 1 MiB each maximum,
  30-second request timeout. Require source freshness <=30 minutes and
  `stale=false`. If provided, honor `x-published-expires-at`. Network/schema
  failure publishes `error`, never last-known-good as a new countdown.
- Current official signal is primary; feed candidates additionally need reset
  context plus delivery/time wording. Classifier labels alone do not trigger AI.
  Only the preceding 24 hours, after the most recent reset, are eligible;
  supplemental posts cannot predate the current official signal. Only Tibo post
  URLs are accepted. Missing optional classifier fields are harmless.
- Match a direct reply parent only by its ID; do not pretend a conversation root
  proves access to every intervening reply. Missing reply metadata, a missing necessary parent, or a nested reply whose full context is not supplied => uncertain.
- On official disappearance/replacement, retire its ID from supplemental
  selection. Reappearance as the explicit official signal may be evaluated again;
  cached interpretation is reused only for identical content/context versions.
- Use `official_signal.window.target_at` / `end_at` first. Different non-null
  values, invalid times or order => uncertain, without AI overriding the conflict.
  Unknown window fields grant no authority. Multiple current candidate posts are
  uncertain even when their proposed times agree; no silent event-identity merge.
- AI returns classification and verbatim evidence, not an authoritative UTC time.
  Code verifies evidence and supported time anchors, then calculates the instant.
  Unsupported wording stays uncertain. The small deterministic checker supports
  Pacific midnight, today/tomorrow/ISO-date + AM/PM time, and explicit
  `within [the] next N hours` (1–24). Exact supported forms are intentionally
  narrower than the model's language understanding. Never accept model timestamps.
- `pacific-local-v1`: PST/PT/PDT all mean `America/Los_Angeles`, including DST,
  by user decision. This deliberately differs from fixed UTC−8 PST. Tomorrow is
  relative to the post's Pacific date; midnight ends that local date. Ambiguous
  or nonexistent DST wall times are uncertain. Deadline must follow publication
  and be no more than 72 hours later. EOD is uncertain. Explicit within-two-hours
  means publication + two elapsed hours. Expired results are removed from current
  deadline selection. Publication is never itself the reset time.
- Negation, conditions, jokes, quoted/uncertain claims and conflicting dates must
  not be explicit. Prompt controls are rejected locally; model boolean semantics
  and evidence are checked too. This is conservative validation, not a proof of
  the truth of a post. Local checks cannot establish the author's sincerity.

## Offline development

```sh
python3.12 -m venv /tmp/reset-service-venv
/tmp/reset-service-venv/bin/python -m pip install -r services/reset-service/requirements-dev.txt
/tmp/reset-service-venv/bin/python -m unittest discover -s services/reset-service/tests -v
actionlint -shellcheck= .github/workflows/reset-service.yml
git diff --check
```

Tests use fixtures and injected HTTP, persistence and time; no DeepSeek key,
network call or Pages deployment. Historical snippets in `tests/fixtures/posts.json`
were read from the attributed feed on 2026-10-25. Relative-two-hours, EOD, DST,
failure and attack cases are synthetic Issue-derived scenarios. Replay times are
fixed, so expired historical posts can be tested deterministically.

## Deployment (requires separate authorization)

The workflow is inert in production until `RESET_SERVICE_ENABLED=true`. PR tests
never receive a Secret. Do **not** enable production merely to validate a PR.

1. Merge the reviewed PR through existing repository policy. This service does
   not authorize merging, bumping the app version, or changing App CI/Release.
2. Check repository Pages settings first. At initial investigation the authenticated
   Pages API returned HTTP 404; no existing Pages site was confirmed. If another
   site exists, stop: deploying this artifact replaces the site's entire content.
   Resolve the site ownership/layout before proceeding. Configure Pages source
   **GitHub Actions**, preserving any environment approval rules and custom domain.
3. Add Actions Secret `RESET_SERVICE_DEEPSEEK_API_KEY`. Use a dedicated low-balance
   key if possible. This is separate from the Release AI secret/configuration.
4. Set Actions variable `RESET_SERVICE_ENABLED=true`, then manually run **Reset
   service** from the default branch with `initialize_state=true` **once**.
   This explicitly creates orphan data branch `reset-service-state`, containing
   only `state.json`. Existing branch/ref makes initialization fail; it never
   replaces or resets an existing ledger. Subsequent runs leave the input false.
5. Verify the actual Pages URL and JSON identity/freshness; record run, head SHA,
   deployment URL and outcome. Await and record a genuine scheduled run too.
   Confirm the same content version adds no paid attempt. Follow the test steps below.

Scheduling targets minutes 2,7,12,…57; GitHub can delay/drop scheduled runs and
suspend inactive public-repository schedules. Manual runs may queue too. Pages/CDN
can serve an old deployment. **There is no fixed-minute publication guarantee.**

The collection job has `contents:write` only for the operational data branch;
GitHub tokens cannot scope that permission to one branch. The separate publishing
job has `pages:write` and `id-token:write`, with no DeepSeek Secret. Production runs
are serialized without cancellation. Existing App checks still run according to
repository policy; this PR does not classify service edits as exempt.

## Ledger, cost and recovery

The state branch is a public operational ledger, not another implementation PR.
It stores content hashes, bounded AI semantic results, request status, usage and
UTC-day counters; it contains no key or account information. Source post text is
public. Reservations are committed through the Contents API with the previously
read SHA (CAS). Missing/inaccessible/corrupt state or a failed save fails closed.
Actions cache/artifact retention is never the dedup or budget authority.

Before every paid attempt: reserve budget and persist `reserved`. After response:
persist `done` or `failed`. A crash between those commits leaves `reserved` and
subsequent runs do not call AI for that version. Failed/invalid analysis is also
terminal across runs. Up to one bounded retry is allowed *within* the original
analysis, sharing the per-run cap. All attempts reserve funds, including failures.
Honor numeric and HTTP-date Retry-After; waits over 30 seconds stop in-run retries.
An invalid header conservatively pauses for an hour. Upstream cooldowns persist
across runs, so the five-minute scheduler cannot bypass a longer Retry-After. Upstream GETs are not retried in
that run, respecting the source's at-most-once-a-minute guidance.

Model: `deepseek-flash`, thinking disabled, JSON response, max output 1,024 tokens.
Limits: **3 attempts/run, 20 attempts/UTC day, $0.10 estimated reserved/day**.
Reservations conservatively count every encoded request byte plus framing as an
input token, at uncached peak $0.30/M input and $1.20/M output (checked 2026-10-25).
The dollar cap can bind earlier than the call cap. Token usage is recorded, but
reservations are not refunded for ambiguous/failed calls. Provider billing and
future price changes are outside this local estimate: recheck
[pricing](https://api-docs.deepseek.com/quick_start/pricing/) before enabling or
changing the model. No search/tools are enabled. See also
[JSON output](https://api-docs.deepseek.com/guides/json_mode/) and
[thinking toggle](https://api-docs.deepseek.com/guides/thinking_mode/).

- To pause: set `RESET_SERVICE_ENABLED=false`; let queued runs finish or cancel
  them knowingly. Existing public JSON expires by its embedded deadline/freshness.
- AI failure/key absent/budget exhausted => uncertain; reliable upstream structured
  time can still be used. Source or state failure => error. No last-known-good is
  promoted into a current result. Deployment failure leaves the previous complete
  Pages artifact; its unchanged `valid_until` is the safety boundary.
- For a reserved/failed analysis: pause and wait for active runs to finish. Inspect
  `state.json` on the state branch, locate the exact content version/post ID and
  check Actions/provider usage. To explicitly authorize re-analysis, delete **only
  that analysis entry**, keeping all `days` counters/reservations and retired IDs;
  commit the maintenance change, resume, then manually run without initialization.
  Do not erase the entire ledger or reset today's counters to bypass the cap.
- Logs expose only controlled status/diagnostic codes, never raw exceptions or AI
  bodies. Ledger `days` and per-analysis `usage` expose request count and costs.
  A failed CAS must not be force-written. Inspect competing writes and rerun safely.
- State writes stop at 900 KB, before GitHub's inline-content threshold. Pause and
  archive the ledger before approaching this limit; do not silently evict dedup
  entries. This bounded MVP does not maintain an unbounded tweet database.

## 如何人工测试

开发版：无 App 变更；离线契约示例为 `services/reset-service/example.json`，不是在线结果。
准备：先完成授权、合并、独立 Secret、Pages 和首次状态初始化；不要用真实 Key 跑 PR 测试。

1. 跑离线测试与 Schema 校验，全部通过；复核示例午夜得到 `07:00Z`。
2. 手动运行生产工作流，确认 ledger 请求预约先于调用；JSON 有来源、版本、方法、
   UTC 时间和不超过 30 分钟的有效期。没有当前有效公告时 `none/uncertain` 也可正确。
3. 同内容再运行一次，确认 `days.attempts` 不增长；等待一次真实 schedule，记录运行链接。
4. 公共 URL 返回完整可解析 JSON；超过 `valid_until` 后按契约判定不可用，不能延续旧倒计时。
5. 离线故障/撤回/冲突/中断/发布失败测试通过；若线上部署失败，确认旧文件的有效期未被刷新。

避免测试：BalanceBar UI、个人额度、#606、X 抓取、账户是否实际重置。
反馈：PASS（注明源码 SHA、运行与部署 URL、范围），或 FAIL + 失败步骤 + 实际/预期。

## Acceptance status

Implementation/offline validation and real deployment acceptance are separate.
At PR delivery: production disabled, no Key used, no Pages deployment, no real
manual/scheduled end-to-end PASS. Keep Issue #607 open until those stronger gates
are verified. App artifacts and GUI acceptance are not applicable.
