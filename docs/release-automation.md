# Release automation

`.github/workflows/release.yml` publishes a Release after a pull request is
merged into `main`.

## Trigger and version detection

The workflow does not require a Release label and does not require a manual Git
tag. It compares `work/balance-bar/Info.plist` in the merged commit with the
first parent of that commit:

- `1.1.3 → 1.1.4` — `c+1`, publishes a beta pre-release such as
  `v1.1.4-beta.1`;
- `1.1.4 → 1.2.0` — `b+1`, publishes a stable release such as `v1.2.0`;
- `1.2.0 → 2.0.0` — `a+1`, publishes a stable release such as `v2.0.0`.

If the version did not change, the workflow exits successfully without
publishing anything. If the version change skips a number or does not reset
the lower components according to the rules above, it fails safely and asks
for a corrected version bump.

## Required GitHub configuration

Add a repository Actions secret named `OPENAI_API_KEY`. Optionally add an
Actions variable named `OPENAI_MODEL` to select the OpenAI model; the workflow
uses `gpt-5.6-terra` when the variable is absent.

The version must already be updated in the merged PR by the Scheduler's normal
release-and-merge step. The workflow reads that version, so it does not create
an extra version commit and does not need permission for the Actions bot to
push to `main`.

## Release description contract

The model returns structured feature and fix items. A checked-in renderer then
creates the exact Release layout used by BalanceBar:

- `## ✨ 新功能` with a `功能 | 说明` table;
- `## 🛠 修复与体验优化` with a `项目 | 说明` table;
- `## 📦 安装` with the versioned DMG filename;
- the `Full Changelog` comparison link.

The description does not contain a separate documentation section. Every
generated row must cite at least one real Issue or PR from the release range,
and every merged PR in that range must appear in at least one row.

If the OpenAI call, structured-output parsing, or source validation fails, the
workflow stops before pushing the tag or publishing the Release. This preserves
the exact-format and traceability guarantees.

The production build uploads `BalanceBar-{version}.dmg` and its SHA-256 file
as Release assets.
