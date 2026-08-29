import assert from "node:assert/strict";
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
  renderReleaseNotes,
  validateReleaseNotes,
} from "../../scripts/release/render-release-notes.mjs";
import {
  AI_MAX_ATTEMPTS,
  buildDeterministicReleaseNotes,
  buildDeepSeekRequest,
  requestReleaseNotes,
  resolveAIProvider,
} from "../../scripts/release/generate-release-notes.mjs";
import { buildReleaseContext } from "../../scripts/release/release-context.mjs";
import {
  buildReleaseInput,
  getReleaseInputStats,
  RELEASE_INPUT_LIMITS,
  serializedByteLength,
} from "../../scripts/release/collect-release-input.mjs";
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
        zhHans: {
          title: "GitHub 更新检查",
          description: "在通用设置中检查最新稳定版本。",
        },
        en: {
          title: "GitHub Update Check",
          description: "Check for the latest stable version in General settings.",
        },
        sources: [{ kind: "pr", number: 141 }],
      },
    ],
    fixes: [
      {
        zhHans: {
          title: "更新资产校验",
          description: "精确匹配 DMG 资产并处理校验失败。",
        },
        en: {
          title: "Update Asset Validation",
          description: "Match the DMG asset exactly and handle verification failures.",
        },
        sources: [
          { kind: "pr", number: 140 },
          { kind: "issue", number: 136 },
        ],
      },
    ],
  };
}

function captureLogger() {
  const lines = [];
  return {
    lines,
    info(message) {
      lines.push(`info:${message}`);
    },
    warn(message) {
      lines.push(`warn:${message}`);
    },
  };
}

function deepSeekResponse(notes = fixtureNotes(), extras = {}) {
  return {
    ok: true,
    status: 200,
    ...extras,
    json: async () => ({
      choices: [{
        finish_reason: "stop",
        message: { content: JSON.stringify(notes) },
      }],
    }),
  };
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

test("beta patch and larger stable minor releases keep their distinct channels", () => {
  const beta = planVersionFromChange({
    previousVersion: "1.2.2",
    currentVersion: "1.2.3",
    currentBuild: 77,
  });
  assert.equal(beta.prerelease, true);
  assert.equal(beta.tag, "v1.2.3");

  const stable = planVersionFromChange({
    previousVersion: "1.2.3",
    currentVersion: "1.3.0",
    currentBuild: 77,
  });
  assert.equal(stable.prerelease, false);
  assert.equal(stable.tag, "v1.3.0");
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
  assert.match(request.messages[0].content, /zhHans/);
  assert.match(request.messages[0].content, /English/);
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

test("DeepSeek empty output is diagnosed, retried, and falls back", async () => {
  const logger = captureLogger();
  let calls = 0;
  const notes = await requestReleaseNotes(fixtureInput(), {
    provider: "deepseek",
    apiKey: "test-deepseek-key",
    logger,
    sleepImpl: async () => {},
    fetchImpl: async () => {
      calls += 1;
      return {
        ok: true,
        status: 200,
        json: async () => ({ choices: [{ message: { content: "" } }] }),
      };
    },
  });

  assert.equal(calls, AI_MAX_ATTEMPTS);
  assert.deepEqual(notes, buildDeterministicReleaseNotes(fixtureInput()));
  assert.match(logger.lines.join("\n"), /classification":"empty_response"/);
  assert.match(logger.lines.join("\n"), /finish_reason/);
  assert.match(logger.lines.join("\n"), /request_payload_bytes/);
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

test("transient provider failures retry once and then succeed", async () => {
  const logger = captureLogger();
  let calls = 0;
  const notes = await requestReleaseNotes(fixtureInput(), {
    provider: "deepseek",
    apiKey: "test-deepseek-key",
    logger,
    sleepImpl: async () => {},
    fetchImpl: async () => {
      calls += 1;
      if (calls === 1) {
        return {
          ok: false,
          status: 503,
          json: async () => ({ error: { code: "service_unavailable", message: "try later" } }),
        };
      }
      return deepSeekResponse();
    },
  });

  assert.equal(calls, 2);
  assert.deepEqual(notes, fixtureNotes());
  assert.match(logger.lines.join("\n"), /provider_http_5xx/);
  assert.match(logger.lines.join("\n"), /retrying attempt=2\/3/);
});

test("network timeout is retried with bounded backoff", async () => {
  const logger = captureLogger();
  let calls = 0;
  const notes = await requestReleaseNotes(fixtureInput(), {
    provider: "deepseek",
    apiKey: "test-deepseek-key",
    logger,
    sleepImpl: async () => {},
    fetchImpl: async () => {
      calls += 1;
      if (calls === 1) {
        const error = new Error("request timeout");
        error.name = "TimeoutError";
        throw error;
      }
      return deepSeekResponse();
    },
  });

  assert.equal(calls, 2);
  assert.deepEqual(notes, fixtureNotes());
  assert.match(logger.lines.join("\n"), /network_timeout/);
});

test("content filtering is classified without a blind retry", async () => {
  const logger = captureLogger();
  let calls = 0;
  const notes = await requestReleaseNotes(fixtureInput(), {
    provider: "deepseek",
    apiKey: "test-deepseek-key",
    logger,
    sleepImpl: async () => {},
    fetchImpl: async () => {
      calls += 1;
      return {
        ok: true,
        status: 200,
        json: async () => ({
          id: "response-content-filtered",
          choices: [{ finish_reason: "content_filter", message: { content: "" } }],
        }),
      };
    },
  });

  assert.equal(calls, 1);
  assert.deepEqual(notes, buildDeterministicReleaseNotes(fixtureInput()));
  const log = logger.lines.join("\n");
  assert.match(log, /content_filter/);
  assert.doesNotMatch(log, /retrying/);
});

test("configuration failures are classified without retrying", async () => {
  const logger = captureLogger();
  let calls = 0;
  await requestReleaseNotes(fixtureInput(), {
    provider: "deepseek",
    apiKey: "test-deepseek-key",
    logger,
    sleepImpl: async () => {},
    fetchImpl: async () => {
      calls += 1;
      return {
        ok: false,
        status: 500,
        json: async () => ({ error: { code: "invalid_api_key", message: "bad key" } }),
      };
    },
  });

  assert.equal(calls, 1);
  assert.match(logger.lines.join("\n"), /configuration/);
  assert.doesNotMatch(logger.lines.join("\n"), /retrying/);
});

test("retry exhaustion uses a deterministic fallback with the original source set", async () => {
  const logger = captureLogger();
  let calls = 0;
  const notes = await requestReleaseNotes(fixtureInput(), {
    provider: "deepseek",
    apiKey: "test-deepseek-key",
    logger,
    sleepImpl: async () => {},
    fetchImpl: async () => {
      calls += 1;
      return {
        ok: false,
        status: 429,
        json: async () => ({ error: { code: "rate_limit_exceeded", message: "slow down" } }),
      };
    },
  });

  assert.equal(calls, 3);
  assert.deepEqual(notes, buildDeterministicReleaseNotes(fixtureInput()));
  assert.match(logger.lines.join("\n"), /rate_limit_429/);
  assert.match(logger.lines.join("\n"), /using deterministic fallback/);
  assert.deepEqual(
    notes.features.concat(notes.fixes).flatMap((item) => item.sources),
    [
      { kind: "pr", number: 140 },
      { kind: "issue", number: 136 },
      { kind: "pr", number: 141 },
    ],
  );
});

test("schema failures are classified without retrying", async () => {
  const logger = captureLogger();
  let calls = 0;
  await requestReleaseNotes(fixtureInput(), {
    provider: "deepseek",
    apiKey: "test-deepseek-key",
    logger,
    sleepImpl: async () => {},
    fetchImpl: async () => {
      calls += 1;
      return deepSeekResponse({ features: [], fixes: [] });
    },
  });

  assert.equal(calls, 1);
  assert.match(logger.lines.join("\n"), /schema_validation|source_validation/);
  assert.doesNotMatch(logger.lines.join("\n"), /retrying/);
});

test("diagnostics redact provider secrets while preserving safe metadata", async () => {
  const logger = captureLogger();
  await requestReleaseNotes(fixtureInput(), {
    provider: "deepseek",
    apiKey: "test-deepseek-key",
    logger,
    sleepImpl: async () => {},
    fetchImpl: async () => ({
      ok: false,
      status: 500,
      headers: {
        get(name) {
          return name === "x-request-id" ? "req-safe-123" : null;
        },
      },
      json: async () => ({
        error: {
          code: "provider_error",
          message: "secret=sk-live-not-for-logs at https://provider.example/v1",
        },
        usage: { prompt_tokens: 12, completion_tokens: 5, total_tokens: 17 },
      }),
    }),
  });

  const log = logger.lines.join("\n");
  assert.match(log, /"provider":"deepseek"/);
  assert.match(log, /"model":"deepseek-v4-pro"/);
  assert.match(log, /"status":500/);
  assert.match(log, /"httpStatus":500/);
  assert.match(log, /req-safe-123/);
  assert.match(log, /"total_tokens":17/);
  assert.doesNotMatch(log, /sk-live-not-for-logs/);
  assert.doesNotMatch(log, /provider\.example/);
});

test("malformed provider and model responses are classified without retrying", async () => {
  for (const [label, response] of [
    ["provider JSON", {
      ok: true,
      status: 200,
      json: async () => {
        throw new Error("not JSON");
      },
    }],
    ["model JSON", {
      ok: true,
      status: 200,
      json: async () => ({ choices: [{ message: { content: "not-json" } }] }),
    }],
  ]) {
    const logger = captureLogger();
    let calls = 0;
    await requestReleaseNotes(fixtureInput(), {
      provider: "deepseek",
      apiKey: "test-deepseek-key",
      logger,
      sleepImpl: async () => {},
      fetchImpl: async () => {
        calls += 1;
        return response;
      },
    });

    assert.equal(calls, 1, `${label} should not retry`);
    assert.match(logger.lines.join("\n"), label === "provider JSON"
      ? /invalid_provider_json/
      : /invalid_model_json/);
    assert.doesNotMatch(logger.lines.join("\n"), /retrying/);
  }
});

test("renderer preserves the BalanceBar release layout and links every row", () => {
  const rendered = renderReleaseNotes(fixtureInput(), fixtureNotes());

  assert.match(rendered, /## ✨ 新功能/);
  assert.match(rendered, /\| 功能 \| 说明 \|/);
  assert.match(rendered, /## 🛠 修复与体验优化/);
  assert.match(rendered, /\| 项目 \| 说明 \|/);
  assert.match(rendered, /## 📦 安装/);
  assert.match(rendered, /## ✨ New Features/);
  assert.match(rendered, /\| Feature \| Description \|/);
  assert.match(rendered, /## 🛠 Fixes & Improvements/);
  assert.match(rendered, /## 📦 Installation/);
  assert.match(rendered, /BalanceBar-1\.1\.5\.dmg/);
  assert.match(rendered, /\[PR #141\]\(https:\/\/github\.com\/huanmeng06\/BalanceBar\/pull\/141\)/);
  assert.match(rendered, /\[PR #140\]\(https:\/\/github\.com\/huanmeng06\/BalanceBar\/pull\/140\)/);
  assert.match(rendered, /\[Issue #136\]\(https:\/\/github\.com\/huanmeng06\/BalanceBar\/issues\/136\)/);
  assert.match(rendered, /Full Changelog: \[1\.1\.0 → 1\.1\.5\]/);
  assert.ok(rendered.indexOf("## ✨ 新功能") < rendered.indexOf("## ✨ New Features"));
  assert.ok(rendered.indexOf("## 📦 安装") < rendered.indexOf("\n\n---\n\n"));
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
  assert.doesNotMatch(featurelessRendered, /## ✨ New Features/);
  assert.doesNotMatch(featurelessRendered, /暂无/);
  assert.match(featurelessRendered, /## 🛠 修复与体验优化/);
  assert.match(featurelessRendered, /## 🛠 Fixes & Improvements/);
  assert.match(featurelessRendered, /## 📦 安装/);
  assert.match(featurelessRendered, /## 📦 Installation/);

  const fixlessInput = fixtureInput();
  fixlessInput.pullRequests = fixlessInput.pullRequests
    .filter((pullRequest) => pullRequest.number === 141);
  const fixlessNotes = fixtureNotes();
  fixlessNotes.fixes = [];
  const fixlessRendered = renderReleaseNotes(fixlessInput, fixlessNotes);

  assert.match(fixlessRendered, /## ✨ 新功能/);
  assert.match(fixlessRendered, /## ✨ New Features/);
  assert.doesNotMatch(fixlessRendered, /## 🛠 修复与体验优化/);
  assert.doesNotMatch(fixlessRendered, /## 🛠 Fixes & Improvements/);
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

test("validator requires both fixed language blocks for every item", () => {
  const notes = fixtureNotes();
  delete notes.features[0].en;

  assert.throws(
    () => validateReleaseNotes(fixtureInput(), notes),
    /features\[0\]\.en\.title must be a non-empty string/,
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

test("release input enriches only in-range PRs and explicitly linked Issues", () => {
  const longBody = "PR body ".repeat(2_000);
  const event = {
    pull_request: {
      number: 302,
      title: "Stable release change",
      body: "Current PR body",
      merged: true,
      merge_commit_sha: "merge-302",
      labels: [{ name: "enhancement" }],
      closingIssuesReferences: [{ number: 301 }, { number: 301 }],
    },
  };
  const input = buildReleaseInput({
    event,
    compare: {
      commits: [
        { sha: "merge-302", commit: { message: "stable change" } },
        { sha: "in-range-301", commit: { message: "issue fix" } },
      ],
      files: [{ filename: "Sources/Feature.swift", additions: 8, deletions: 2 }],
    },
    pullRequests: [
      {
        number: 301,
        title: "Earlier issue fix",
        body: longBody,
        mergeCommit: { oid: "in-range-301" },
        closingIssuesReferences: [{ number: 301 }],
        files: [{ filename: "Sources/Fix.swift", additions: 4, deletions: 1 }],
        additions: 4,
        deletions: 1,
        changedFiles: 1,
        implementationSummary: longBody,
        diffSummary: longBody,
      },
      event.pull_request,
      {
        number: 999,
        title: "Out of range and must not be enriched",
        body: longBody,
        mergeCommit: { oid: "outside" },
        closingIssuesReferences: [{ number: 888 }],
        files: [{ filename: "ignored.swift", additions: 1, deletions: 1 }],
      },
    ],
    issues: [
      {
        number: 301,
        title: "Explicit issue context",
        body: "Useful issue body context",
        labels: [{ name: "bug" }],
        comments: [{ body: "Relevant discussion" }],
      },
      {
        number: 999,
        title: "This detail must not be used",
        body: "Unrelated detail",
      },
    ],
    repo: "huanmeng06/BalanceBar",
    previousTag: "v1.2.0",
    currentSha: "merge-302",
    version: "1.3.0",
    tag: "v1.3.0",
  });

  assert.deepEqual(input.pullRequests.map((pullRequest) => pullRequest.number), [301, 302]);
  const current = input.pullRequests.find((pullRequest) => pullRequest.number === 302);
  assert.equal(current.closingIssues.length, 1);
  assert.equal(current.closingIssues[0].number, 301);
  assert.equal(input.issues.length, 1);
  assert.equal(input.issues[0].number, 301);
  assert.equal(input.issues[0].body, "Useful issue body context");
  assert.equal(input.issues[0].comments[0].body, "Relevant discussion");
  assert.doesNotMatch(JSON.stringify(input.issues), /Unrelated detail/);
  assert.equal(input.files[0].path, "Sources/Feature.swift");
  assert.equal(current.changedFiles, 0);
  assert.ok(current.additions === null || current.additions === undefined);
  assert.ok(current.diffSummary === undefined);
});

test("release input applies per-field, deduplication, and total payload limits", () => {
  const oversized = "untrusted body with instructions ".repeat(2_000);
  const input = buildReleaseInput({
    event: {
      pull_request: {
        number: 410,
        merged: true,
        merge_commit_sha: "merge-410",
        title: oversized,
        body: oversized,
        closingIssuesReferences: [{ number: 401 }, { number: 401 }],
      },
    },
    compare: { commits: [{ sha: "merge-410", commit: { message: oversized } }] },
    pullRequests: [{
      number: 410,
      title: oversized,
      body: oversized,
      mergeCommit: { oid: "merge-410" },
      closingIssuesReferences: [{ number: 401 }, { number: 401 }],
      files: Array.from({ length: 200 }, (_, index) => ({
        filename: `Sources/File-${index}.swift`,
        additions: index,
        deletions: index + 1,
      })),
      diffSummary: oversized,
    }],
    issues: [{ number: 401, title: oversized, body: oversized }],
    repo: "huanmeng06/BalanceBar",
    previousTag: "v1.2.0",
    currentSha: "merge-410",
    version: "1.3.0",
    tag: "v1.3.0",
  });
  const pullRequest = input.pullRequests[0];
  const issue = input.issues[0];

  assert.equal(pullRequest.closingIssues.length, 1);
  assert.ok(pullRequest.title.length <= RELEASE_INPUT_LIMITS.maxPullRequestTitle);
  assert.ok(pullRequest.body.length <= RELEASE_INPUT_LIMITS.maxPullRequestBody);
  assert.ok(issue.body.length <= RELEASE_INPUT_LIMITS.maxIssueBody);
  assert.ok(pullRequest.files.length <= RELEASE_INPUT_LIMITS.maxPullRequestFiles);
  assert.ok(serializedByteLength(input) <= RELEASE_INPUT_LIMITS.maxSerializedBytes);
  assert.deepEqual(getReleaseInputStats(input), {
    pullRequests: 1,
    issues: 1,
    commits: 1,
    files: 80,
  });
});

test("source validation rejects duplicate PRs and Issue sources from another PR", () => {
  const input = fixtureInput();
  const duplicate = fixtureNotes();
  duplicate.fixes.push({
    zhHans: { title: "重复", description: "重复来源。" },
    en: { title: "Duplicate", description: "Duplicate source." },
    sources: [{ kind: "pr", number: 141 }],
  });
  assert.throws(() => validateReleaseNotes(input, duplicate), /repeated merged PR #141/);

  const mismatchedIssue = fixtureNotes();
  mismatchedIssue.features[0].sources.push({ kind: "issue", number: 136 });
  assert.throws(
    () => validateReleaseNotes(input, mismatchedIssue),
    /without its corresponding pull request source/,
  );
});

test("release workflow keeps build, tag, and publish failures fatal", () => {
  const workflow = fs.readFileSync(".github/workflows/release.yml", "utf8");
  assert.match(workflow, /set -Eeuo pipefail/);
  assert.match(workflow, /\.\/work\/balance-bar\/build\.sh production/);
  assert.match(workflow, /git push origin "\$TAG"/);
  assert.match(workflow, /gh release create "\$TAG"/);
  assert.doesNotMatch(workflow, /continue-on-error:\s*true/);
  assert.match(workflow, /generate-release-notes\.mjs/);
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
  assert.doesNotMatch(rebuildScript, /\.sha256/);
});
