import assert from "node:assert/strict";
import crypto from "node:crypto";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import test from "node:test";

import {
  classifyVersionChange,
  planVersion,
  planVersionFromChange,
  readVersionFromPlist,
  updatePlist,
} from "../../scripts/release/version.mjs";
import {
  RELEASE_NOTES_LOCALES,
  renderLocalizedReleaseNotes,
  renderReleaseNotes,
  validateReleaseNotes,
} from "../../scripts/release/render-release-notes.mjs";
import {
  buildDeepSeekRequest,
  buildLocalizedDeepSeekRequest,
  requestLocalizedReleaseNotes,
  requestReleaseNotes,
  resolveAIProvider,
} from "../../scripts/release/generate-release-notes.mjs";
import {
  buildReleaseNotesAssetBundle,
  verifyReleaseNotesInventory,
} from "../../scripts/release/build-release-notes-assets.mjs";
import { buildReleaseContext } from "../../scripts/release/release-context.mjs";
import { buildReleaseInput } from "../../scripts/release/collect-release-input.mjs";
import {
  selectPreviousRelease,
} from "../../scripts/release/select-previous-release.mjs";

function fixtureInput() {
  return {
    repo: "huanmeng06/BalanceBar",
    currentSha: "1411411411411411411411411411411411411411",
    version: "1.1.5",
    tag: "v1.1.5",
    previousTag: "v1.1.0",
    previousVersion: "1.1.0",
    compareUrl: "https://github.com/huanmeng06/BalanceBar/compare/v1.1.0...v1.1.5",
    pullRequests: [
      {
        number: 140,
        closingIssues: [{ number: 136 }],
      },
      {
        number: 141,
        closingIssues: [],
      },
    ],
    commits: [],
    files: [],
  };
}

function fixtureNotes() {
  return {
    features: [
      {
        title: "GitHub 更新检查",
        description: "在通用设置中检查最新稳定版本。",
        sources: [{ kind: "pr", number: 141 }],
      },
    ],
    fixes: [
      {
        title: "更新资产校验",
        description: "精确匹配 DMG 资产并处理校验失败。",
        sources: [
          { kind: "pr", number: 140 },
          { kind: "issue", number: 136 },
        ],
      },
    ],
  };
}

function localizedFixtureNotes() {
  return Object.fromEntries(RELEASE_NOTES_LOCALES.map((locale) => [
    locale,
    {
      features: [{
        title: `${locale} feature`,
        description: `${locale} feature description`,
        sources: [{ kind: "pr", number: 141 }],
      }],
      fixes: [{
        title: `${locale} fix`,
        description: `${locale} fix description`,
        sources: [
          { kind: "pr", number: 140 },
          { kind: "issue", number: 136 },
        ],
      }],
    },
  ]));
}

test("patch and minor plans follow the release policy", () => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), "balancebar-release-"));
  const plistPath = path.join(directory, "Info.plist");
  fs.writeFileSync(plistPath, `
<key>CFBundleShortVersionString</key>
<string>1.1.4</string>
<key>CFBundleVersion</key>
<string>28</string>
`);

  const patchPlan = planVersion({
    plistPath,
    bump: "patch",
  });
  assert.equal(patchPlan.version, "1.1.5");
  assert.equal(patchPlan.build, 29);
  assert.equal(patchPlan.prerelease, true);
  assert.equal(patchPlan.tag, "v1.1.5");

  const minorPlan = planVersion({ plistPath, bump: "minor" });
  assert.equal(minorPlan.version, "1.2.0");
  assert.equal(minorPlan.prerelease, false);
  assert.equal(minorPlan.tag, "v1.2.0");

  updatePlist(plistPath, patchPlan);
  assert.deepEqual(readVersionFromPlist(plistPath), {
    version: "1.1.5",
    build: 29,
  });
  fs.rmSync(directory, { recursive: true, force: true });
});

test("existing version changes are classified without incrementing again", () => {
  assert.equal(classifyVersionChange("1.1.3", "1.1.4"), "patch");
  assert.equal(classifyVersionChange("1.1.4", "1.2.0"), "minor");
  assert.equal(classifyVersionChange("1.2.0", "2.0.0"), "major");

  const patchPlan = planVersionFromChange({
    previousVersion: "1.1.3",
    currentVersion: "1.1.4",
    currentBuild: 28,
  });
  assert.equal(patchPlan.version, "1.1.4");
  assert.equal(patchPlan.build, 28);
  assert.equal(patchPlan.prerelease, true);
  assert.equal(patchPlan.tag, "v1.1.4");

  const minorPlan = planVersionFromChange({
    previousVersion: "1.1.4",
    currentVersion: "1.2.0",
    currentBuild: 29,
  });
  assert.equal(minorPlan.version, "1.2.0");
  assert.equal(minorPlan.prerelease, false);
  assert.equal(minorPlan.tag, "v1.2.0");

  assert.throws(
    () => classifyVersionChange("1.1.3", "1.1.5"),
    /Unsupported version change/,
  );
});

test("pre-release comparisons use the immediately preceding release", () => {
  const previous = selectPreviousRelease({
    currentVersion: "1.2.3",
    prerelease: true,
    releases: [
      { tagName: "v1.1.22", isPrerelease: true },
      { tagName: "v1.2.0", isPrerelease: false },
      { tagName: "v1.2.2", isPrerelease: true },
      { tagName: "v1.2.1", isPrerelease: true },
      { tagName: "v1.3.0", isPrerelease: false },
    ],
  });

  assert.equal(previous?.tagName, "v1.2.2");
});

test("stable comparisons use the preceding stable release and include pre-releases", () => {
  const previous = selectPreviousRelease({
    currentVersion: "1.3.0",
    prerelease: false,
    releases: [
      { tagName: "v1.1.0", isPrerelease: false },
      { tagName: "v1.2.0", isPrerelease: false },
      { tagName: "v1.2.1", isPrerelease: true },
      { tagName: "v1.2.2", isPrerelease: true },
      { tagName: "v1.3.0", isPrerelease: false },
    ],
  });

  assert.equal(previous?.tagName, "v1.2.0");
});

test("release context ignores build-only changes and detects version changes", () => {
  const event = {
    pull_request: {
      number: 142,
      html_url: "https://github.com/huanmeng06/BalanceBar/pull/142",
      merged: true,
    },
  };

  const buildOnly = buildReleaseContext({
    event,
    mergeSha: "merge-142",
    parentSha: "parent-142",
    previous: { version: "1.1.4", build: 28 },
    current: { version: "1.1.4", build: 29 },
  });
  assert.equal(buildOnly.should_release, "false");
  assert.equal(buildOnly.bump, undefined);

  const patch = buildReleaseContext({
    event,
    mergeSha: "merge-142",
    parentSha: "parent-142",
    previous: { version: "1.1.4", build: 28 },
    current: { version: "1.1.5", build: 29 },
  });
  assert.equal(patch.should_release, "true");
  assert.equal(patch.bump, "patch");
});

test("DeepSeek is the default provider and uses JSON chat completions", async () => {
  assert.equal(resolveAIProvider(""), "deepseek");

  const request = buildDeepSeekRequest(fixtureInput(), "deepseek-v4-pro");
  assert.equal(request.model, "deepseek-v4-pro");
  assert.deepEqual(request.response_format, { type: "json_object" });
  assert.match(request.messages[0].content, /JSON/);
  assert.match(request.messages[0].content, /"number": 140/);
  assert.match(request.messages[1].content, /v1\.1\.5/);

  let observedUrl;
  let observedOptions;
  const notes = await requestReleaseNotes(fixtureInput(), {
    provider: "deepseek",
    apiKey: "test-deepseek-key",
    model: "deepseek-v4-pro",
    fetchImpl: async (url, options) => {
      observedUrl = url;
      observedOptions = options;
      return {
        ok: true,
        status: 200,
        json: async () => ({
          choices: [{ message: { content: JSON.stringify(fixtureNotes()) } }],
        }),
      };
    },
  });

  assert.equal(observedUrl, "https://api.deepseek.com/chat/completions");
  assert.equal(observedOptions.headers.Authorization, "Bearer test-deepseek-key");
  assert.deepEqual(notes, fixtureNotes());
  assert.equal(JSON.parse(observedOptions.body).response_format.type, "json_object");
});

test("DeepSeek empty JSON output fails closed", async () => {
  await assert.rejects(
    () => requestReleaseNotes(fixtureInput(), {
      provider: "deepseek",
      apiKey: "test-deepseek-key",
      fetchImpl: async () => ({
        ok: true,
        status: 200,
        json: async () => ({ choices: [{ message: { content: "" } }] }),
      }),
    }),
    /DeepSeek response did not contain output text/,
  );
});

test("OpenAI remains available as an explicit provider", async () => {
  assert.equal(resolveAIProvider("openai"), "openai");

  let observedUrl;
  const notes = await requestReleaseNotes(fixtureInput(), {
    provider: "openai",
    apiKey: "test-openai-key",
    model: "gpt-5.6-terra",
    fetchImpl: async (url, options) => {
      observedUrl = url;
      const request = JSON.parse(options.body);
      assert.equal(request.text.format.type, "json_schema");
      return {
        ok: true,
        status: 200,
        json: async () => ({
          status: "completed",
          output_text: JSON.stringify(fixtureNotes()),
        }),
      };
    },
  });

  assert.equal(observedUrl, "https://api.openai.com/v1/responses");
  assert.deepEqual(notes, fixtureNotes());
});

test("localized release-note requests preserve canonical sources and cover all locales", async () => {
  const expected = localizedFixtureNotes();
  const request = buildLocalizedDeepSeekRequest(fixtureNotes(), "deepseek-v4-pro");
  assert.equal(request.model, "deepseek-v4-pro");
  assert.match(request.messages[0].content, /zh-Hans/);
  assert.match(request.messages[0].content, /sources arrays/);

  let observedUrl;
  const notes = await requestLocalizedReleaseNotes(fixtureInput(), fixtureNotes(), {
    provider: "deepseek",
    apiKey: "test-deepseek-key",
    fetchImpl: async (url) => {
      observedUrl = url;
      return {
        ok: true,
        status: 200,
        json: async () => ({ choices: [{ message: { content: JSON.stringify(expected) } }] }),
      };
    },
  });

  assert.equal(observedUrl, "https://api.deepseek.com/chat/completions");
  assert.deepEqual(notes, expected);
});

test("versioned notes assets contain an exact eight-locale manifest and verified inventory", () => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), "balancebar-notes-assets-"));
  const bundle = buildReleaseNotesAssetBundle({
    input: fixtureInput(),
    canonicalNotes: fixtureNotes(),
    localizedNotes: localizedFixtureNotes(),
    outputDir: directory,
  });

  assert.equal(bundle.files.length, 8);
  assert.deepEqual(Object.keys(bundle.manifest.locales).sort(), [...RELEASE_NOTES_LOCALES].sort());
  assert.match(fs.readFileSync(bundle.files.find((file) => file.locale === "en").path, "utf8"), /## ✨ New Features/);
  assert.match(fs.readFileSync(bundle.files.find((file) => file.locale === "de").path, "utf8"), /## ✨ Neue Funktionen/);

  const manifestData = fs.readFileSync(bundle.manifestPath);
  const releaseAssets = [
    { name: `BalanceBar-${fixtureInput().version}.dmg`, size: 1, digest: null },
    {
      name: bundle.manifestName,
      size: manifestData.length,
      digest: `sha256:${crypto.createHash("sha256").update(manifestData).digest("hex")}`,
    },
    ...bundle.files.map((file) => ({
      name: file.name,
      size: file.size,
      digest: `sha256:${file.sha256}`,
    })),
  ];
  assert.equal(verifyReleaseNotesInventory({
    input: fixtureInput(),
    manifest: bundle.manifest,
    manifestData,
    releaseAssets,
  }), true);
  fs.rmSync(directory, { recursive: true, force: true });
});

test("asset generation rejects unsafe Markdown and manifest source drift", () => {
  const unsafe = localizedFixtureNotes();
  unsafe.en.features[0].title = "<script>alert(1)</script>";
  assert.throws(
    () => buildReleaseNotesAssetBundle({
      input: fixtureInput(),
      canonicalNotes: fixtureNotes(),
      localizedNotes: unsafe,
      outputDir: fs.mkdtempSync(path.join(os.tmpdir(), "balancebar-notes-unsafe-")),
    }),
    /raw HTML/,
  );

  const drifted = localizedFixtureNotes();
  drifted.ja.features[0].sources = [{ kind: "pr", number: 140 }];
  assert.throws(
    () => buildReleaseNotesAssetBundle({
      input: fixtureInput(),
      canonicalNotes: fixtureNotes(),
      localizedNotes: drifted,
      outputDir: fs.mkdtempSync(path.join(os.tmpdir(), "balancebar-notes-drift-")),
    }),
    /changed canonical sources/,
  );
});

test("renderer preserves the BalanceBar release layout and links every row", () => {
  const rendered = renderReleaseNotes(fixtureInput(), fixtureNotes());

  assert.match(rendered, /## ✨ 新功能/);
  assert.match(rendered, /功能 \| 说明/);
  assert.match(rendered, /## 🛠 修复与体验优化/);
  assert.match(rendered, /项目 \| 说明/);
  assert.match(rendered, /## 📦 安装/);
  assert.match(rendered, /BalanceBar-1\.1\.5\.dmg/);
  assert.match(rendered, /\[PR #141\]\(https:\/\/github\.com\/huanmeng06\/BalanceBar\/pull\/141\)/);
  assert.match(rendered, /\[PR #140\]\(https:\/\/github\.com\/huanmeng06\/BalanceBar\/pull\/140\)/);
  assert.match(rendered, /\[Issue #136\]\(https:\/\/github\.com\/huanmeng06\/BalanceBar\/issues\/136\)/);
  assert.match(rendered, /Full Changelog: \[1\.1\.0 → 1\.1\.5\]/);
  assert.doesNotMatch(rendered, /## 📚 文档|架构说明|开发工作流/);
});

test("renderer omits empty feature or fix sections", () => {
  const featurelessInput = fixtureInput();
  featurelessInput.pullRequests = featurelessInput.pullRequests
    .filter((pullRequest) => pullRequest.number === 140);
  const featurelessNotes = fixtureNotes();
  featurelessNotes.features = [];
  const featurelessRendered = renderReleaseNotes(featurelessInput, featurelessNotes);

  assert.doesNotMatch(featurelessRendered, /## ✨ 新功能/);
  assert.doesNotMatch(featurelessRendered, /暂无/);
  assert.match(featurelessRendered, /## 🛠 修复与体验优化/);
  assert.match(featurelessRendered, /## 📦 安装/);

  const fixlessInput = fixtureInput();
  fixlessInput.pullRequests = fixlessInput.pullRequests
    .filter((pullRequest) => pullRequest.number === 141);
  const fixlessNotes = fixtureNotes();
  fixlessNotes.fixes = [];
  const fixlessRendered = renderReleaseNotes(fixlessInput, fixlessNotes);

  assert.match(fixlessRendered, /## ✨ 新功能/);
  assert.doesNotMatch(fixlessRendered, /## 🛠 修复与体验优化/);
  assert.doesNotMatch(fixlessRendered, /暂无/);
});

test("renderer ignores an unlinked Issue when the item has a valid PR source", () => {
  const notes = fixtureNotes();
  notes.features[0].sources.push({ kind: "issue", number: 143 });

  const rendered = renderReleaseNotes(fixtureInput(), notes);

  assert.match(rendered, /\[PR #141\]\(https:\/\/github\.com\/huanmeng06\/BalanceBar\/pull\/141\)/);
  assert.doesNotMatch(rendered, /\[Issue #143\]/);
});

test("validator rejects an item that omits a merged PR", () => {
  const notes = fixtureNotes();
  notes.features[0].sources = [{ kind: "issue", number: 136 }];

  assert.throws(
    () => validateReleaseNotes(fixtureInput(), notes),
    /Release notes omitted merged PR\(s\): #141/,
  );
});

test("validator rejects invented sources", () => {
  const notes = fixtureNotes();
  notes.features[0].sources = [{ kind: "pr", number: 999 }];

  assert.throws(
    () => validateReleaseNotes(fixtureInput(), notes),
    /AI cited PR #999/,
  );
});

test("release input includes all PRs represented by compare commits", () => {
  const event = {
    pull_request: {
      number: 141,
      title: "Current merge",
      body: "",
      merged: true,
      merge_commit_sha: "merge-141",
      labels: [],
    },
  };
  const compare = {
    commits: [
      { sha: "merge-141", commit: { message: "Current merge" } },
      { sha: "commit-140", commit: { message: "Earlier fix" } },
    ],
  };
  const pullRequests = [
    {
      number: 140,
      title: "Earlier fix",
      body: "",
      mergeCommit: null,
      commits: [{ oid: "commit-140" }],
      closingIssuesReferences: [],
    },
    event.pull_request,
  ];

  const input = buildReleaseInput({
    event,
    compare,
    pullRequests,
    repo: "huanmeng06/BalanceBar",
    previousTag: "v1.1.0",
    currentSha: "merge-141",
    version: "1.1.5",
    tag: "v1.1.5",
  });

  assert.deepEqual(input.pullRequests.map((pullRequest) => pullRequest.number), [140, 141]);
});

test("manual rebuild is guarded and preserves a DMG-only Release", () => {
  const workflow = fs.readFileSync(".github/workflows/release.yml", "utf8");
  const createDmgScript = fs.readFileSync("scripts/release/create-dmg.sh", "utf8");
  const rebuildScript = fs.readFileSync(
    "scripts/release/rebuild-existing-release.sh",
    "utf8",
  );

  assert.match(workflow, /workflow_dispatch:/);
  assert.match(workflow, /confirm_replace:/);
  assert.match(workflow, /REBUILD_CONFIRM_REPLACE: \$\{\{ inputs\.confirm_replace \}\}/);
  assert.match(workflow, /runs-on: macos-26/);
  assert.match(workflow, /create-dmg\.sh/);
  assert.match(workflow, /rebuild-existing-release\.sh/);

  assert.match(createDmgScript, /ditto "\$app_path" "\$volume_root\/BalanceBar\.app"/);
  assert.match(createDmgScript, /ln -s \/Applications "\$volume_root\/Applications"/);
  assert.match(createDmgScript, /hdiutil verify "\$output_path"/);

  assert.match(rebuildScript, /REBUILD_CONFIRM_REPLACE=true is required/);
  assert.match(rebuildScript, /gh release download/);
  assert.match(rebuildScript, /gh release upload[\s\S]+--clobber/);
  assert.match(rebuildScript, /restoring tag/);
  assert.match(rebuildScript, /restoring DMG/);
  assert.match(rebuildScript, /must contain only \$asset_name after rebuilding/);
  assert.match(rebuildScript, /multilingual notes inventory/);
  assert.match(workflow, /build-release-notes-assets\.mjs/);
  assert.match(workflow, /verify-release-notes-assets\.mjs/);
  assert.match(workflow, /--draft/);
  assert.doesNotMatch(rebuildScript, /\.sha256/);
});
