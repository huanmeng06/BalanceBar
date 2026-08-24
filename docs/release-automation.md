# Release automation

`.github/workflows/release.yml` publishes a Release after a pull request is
merged into `main`.

## Trigger and version detection

The workflow does not require a Release label and does not require a manual Git
tag. It compares `work/balance-bar/Info.plist` in the merged commit with the
first parent of that commit:

- `1.1.3 → 1.1.4` — `c+1`, publishes a Pre-release using the plain tag
  `v1.1.4`;
- `1.1.4 → 1.2.0` — `b+1`, publishes a stable release such as `v1.2.0`;
- `1.2.0 → 2.0.0` — `a+1`, publishes a stable release such as `v2.0.0`.

If the version did not change, the workflow exits successfully without
publishing anything. If the version change skips a number or does not reset
the lower components according to the rules above, it fails safely and asks
for a corrected version bump.

Patch releases use a normal `vX.Y.Z` tag without a beta-number suffix.
GitHub's Pre-release flag identifies the release as a test version; the tag and
Release title remain `vX.Y.Z`.

## AI provider configuration

The default provider is DeepSeek. Add a repository Actions secret named
`DEEPSEEK_API_KEY`. The default model is `deepseek-v4-pro`; set the repository
variable `RELEASE_AI_MODEL` if your account uses another DeepSeek model.

To use OpenAI instead, add the `OPENAI_API_KEY` secret and set the repository
variable `RELEASE_AI_PROVIDER` to `openai`. The default OpenAI model is
`gpt-5.6-terra`; `OPENAI_MODEL` remains supported as a provider-specific
override.

The supported provider values are `deepseek` and `openai`. If no provider
variable is set, `deepseek` is selected. `RELEASE_AI_BASE_URL` is optional and
is intended for a compatible gateway; normally it should be left empty.

The version must already be updated in the merged PR by the Scheduler's normal
release-and-merge step. The workflow reads that version, so it does not create
an extra version commit and does not need permission for the Actions bot to
push to `main`.

## Release description contract

The model returns structured feature and fix items. A checked-in renderer then
creates the exact Release layout used by BalanceBar:

- `## ✨ 新功能` with a `功能 | 说明` table when the release has feature items;
- `## 🛠 修复与体验优化` with a `项目 | 说明` table when the release has fix items;
- `## 📦 安装` with the versioned DMG filename;
- the `Full Changelog` comparison link.

Empty feature or fix arrays are omitted entirely. The renderer does not add a
“暂无……” placeholder section.

The description does not contain a separate documentation section. Every
generated row must cite at least one real Issue or PR from the release range,
and every merged PR in that range must appear in at least one row.

If the selected provider call, JSON parsing, or source validation fails, the
workflow stops before pushing the tag or publishing the Release. DeepSeek JSON
Output is checked again by the local validator, which preserves the
exact-format and traceability guarantees.

The production build uploads `BalanceBar-{version}.dmg` and its SHA-256 file
as Release assets.
