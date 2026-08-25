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

## Previous release comparison

The comparison base depends on whether the new Release is a Pre-release:

- A patch bump is a Pre-release. It compares against the highest lower
  released version, whether that previous Release was Stable or a Pre-release.
  For example, `1.2.3` compares against `1.2.2`.
- A minor or major bump is a Stable/latest Release. It compares against the
  highest lower Stable version, intentionally including every Pre-release
  published after that Stable baseline. For example, `1.3.0` compares against
  `1.2.0` and includes `1.2.1`, `1.2.2`, and other intervening work.

Release publication time is not used to choose the comparison base. This keeps
an out-of-order Pre-release from becoming the base for a later version.

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

The model returns structured feature and fix items with a Simplified Chinese
and an English title/description for each item. A checked-in renderer then
creates one fixed Markdown body in this order:

1. Simplified Chinese sections (`## ✨ 新功能`, `## 🛠 修复与体验优化`, and
   `## 📦 安装`) followed by the `Full Changelog` comparison link;
2. a `---` separator;
3. the matching English sections (`## ✨ New Features`, `## 🛠 Fixes &
   Improvements`, and `## 📦 Installation`) followed by the same comparison
   link.

The two language sections use the same item order and source links. Empty
feature or fix arrays are omitted in both languages together. The renderer
does not add a “暂无……” placeholder section.

The description does not contain a separate documentation section. Every
generated row must cite at least one real Issue or PR from the release range,
and every merged PR in that range must appear in at least one row.

If the selected provider call, JSON parsing, or source validation fails, the
workflow stops before pushing the tag or publishing the Release. DeepSeek JSON
Output is checked again by the local validator, which preserves the
exact-format and traceability guarantees.

The production build uploads only the versioned DMG asset. The client reads
the complete description from `GitHubRelease.body`; no manifest, locale
Markdown, or other release-notes resource is bundled or uploaded.
