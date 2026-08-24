#!/usr/bin/env node

import fs from "node:fs";
import path from "node:path";
import { pathToFileURL } from "node:url";

const SECTION_DEFINITIONS = [
  {
    key: "features",
    heading: "## ✨ 新功能",
    column: "功能",
  },
  {
    key: "fixes",
    heading: "## 🛠 修复与体验优化",
    column: "项目",
  },
];

function sourceKey(source) {
  return `${source.kind}:${source.number}`;
}

function buildIssueCatalog(input) {
  const issues = new Map();
  for (const pullRequest of input.pullRequests ?? []) {
    for (const issue of pullRequest.closingIssues ?? []) {
      issues.set(issue.number, issue);
    }
  }
  return issues;
}

/**
 * Remove only unlinked Issue citations when the same item still has another
 * source. A PR body can mention an issue number without creating a GitHub
 * closing-issue relationship; that prose is not sufficient evidence for an
 * Issue link in the published notes. Items with no valid source still fail in
 * validateReleaseNotes below.
 */
export function sanitizeReleaseNotes(input, notes) {
  const issues = buildIssueCatalog(input);
  const sanitized = { ...notes };

  for (const section of SECTION_DEFINITIONS) {
    if (!Array.isArray(notes?.[section.key])) {
      continue;
    }

    sanitized[section.key] = notes[section.key].map((item, index) => ({
      ...item,
      sources: Array.isArray(item?.sources)
        ? item.sources.filter((source) => {
          if (source?.kind !== "issue") {
            return true;
          }
          if (issues.has(source.number)) {
            return true;
          }
          if (Number.isInteger(source.number) && source.number > 0) {
            console.warn(
              `render-release-notes: ignoring unlinked Issue #${source.number} in ${section.key}[${index}]; preserving other validated sources`,
            );
            return false;
          }
          return true;
        })
        : item?.sources,
    }));
  }

  return sanitized;
}

function oneLine(value, fieldName) {
  if (typeof value !== "string" || value.trim().length === 0) {
    throw new Error(`${fieldName} must be a non-empty string`);
  }

  const valueWithoutNewlines = value.replace(/[\r\n]+/g, " ").trim();
  if (valueWithoutNewlines.startsWith("## ")) {
    throw new Error(`${fieldName} must not contain a Markdown heading`);
  }

  return valueWithoutNewlines;
}

function tableCell(value) {
  return value.replaceAll("|", "\\|");
}

function sourceLink(repo, source) {
  const label = source.kind === "pr" ? "PR" : "Issue";
  const pathName = source.kind === "pr" ? "pull" : "issues";
  return `[${label} #${source.number}](https://github.com/${repo}/${pathName}/${source.number})`;
}

export function validateReleaseNotes(input, notes) {
  if (!notes || typeof notes !== "object" || Array.isArray(notes)) {
    throw new Error("AI release notes must be an object");
  }

  const pullRequests = new Map(
    (input.pullRequests ?? []).map((pullRequest) => [pullRequest.number, pullRequest]),
  );
  const issues = buildIssueCatalog(input);

  const coveredPullRequests = new Set();
  let itemCount = 0;

  for (const section of SECTION_DEFINITIONS) {
    const items = notes[section.key];
    if (!Array.isArray(items)) {
      throw new Error(`AI release notes.${section.key} must be an array`);
    }

    for (const [index, item] of items.entries()) {
      itemCount += 1;
      oneLine(item?.title, `${section.key}[${index}].title`);
      oneLine(item?.description, `${section.key}[${index}].description`);

      if (!Array.isArray(item.sources) || item.sources.length === 0) {
        throw new Error(`${section.key}[${index}] must have at least one Issue or PR source`);
      }

      const seenSources = new Set();
      for (const source of item.sources) {
        if (!source || !["pr", "issue"].includes(source.kind)) {
          throw new Error(`${section.key}[${index}] contains an invalid source kind`);
        }
        if (!Number.isInteger(source.number) || source.number <= 0) {
          throw new Error(`${section.key}[${index}] contains an invalid source number`);
        }

        const key = sourceKey(source);
        if (seenSources.has(key)) {
          throw new Error(`${section.key}[${index}] repeats source ${key}`);
        }
        seenSources.add(key);

        if (source.kind === "pr") {
          if (!pullRequests.has(source.number)) {
            throw new Error(`AI cited PR #${source.number}, which is not in this release range`);
          }
          coveredPullRequests.add(source.number);
        } else if (!issues.has(source.number)) {
          throw new Error(`AI cited Issue #${source.number}, which is not linked to this release range`);
        }
      }
    }
  }

  if (itemCount === 0) {
    throw new Error("AI returned no release note items");
  }

  const missingPullRequests = [...pullRequests.keys()]
    .filter((number) => !coveredPullRequests.has(number));
  if (missingPullRequests.length > 0) {
    throw new Error(
      `Release notes omitted merged PR(s): ${missingPullRequests.map((number) => `#${number}`).join(", ")}`,
    );
  }

  return { coveredPullRequests };
}

function renderSection(input, notes, definition) {
  const items = notes[definition.key];
  if (items.length === 0) {
    return null;
  }

  const rows = items.map((item) => {
    const title = tableCell(oneLine(item.title, `${definition.key}.title`));
    const description = tableCell(oneLine(item.description, `${definition.key}.description`));
    const links = item.sources.map((source) => sourceLink(input.repo, source)).join(", ");
    return [`${title} (${links})`, description];
  });

  return [
    definition.heading,
    "",
    `${definition.column} | 说明`,
    "--- | ---",
    ...rows.map(([name, description]) => `${name} | ${description}`),
  ].join("\n");
}

export function renderReleaseNotes(input, notes) {
  const sanitizedNotes = sanitizeReleaseNotes(input, notes);
  validateReleaseNotes(input, sanitizedNotes);

  const sections = SECTION_DEFINITIONS
    .map((definition) => renderSection(input, sanitizedNotes, definition))
    .filter(Boolean);
  const installation = [
    "## 📦 安装",
    "",
    `1. 下载 Assets 中的 \`BalanceBar-${input.version}.dmg\`。`,
    "2. 打开 DMG，将 `BalanceBar.app` 拖入“应用程序”文件夹。",
    "3. 从“应用程序”文件夹启动 BalanceBar。",
  ].join("\n");
  const changelog = `Full Changelog: [${input.previousVersion} → ${input.version}](${input.compareUrl})`;

  return `${[...sections, installation, changelog].join("\n\n")}\n`;
}

function parseArguments(argv) {
  const options = {};
  for (let index = 0; index < argv.length; index += 1) {
    const key = argv[index];
    if (!key.startsWith("--")) {
      continue;
    }
    options[key.slice(2)] = argv[index + 1];
    index += 1;
  }
  return options;
}

function main() {
  const options = parseArguments(process.argv.slice(2));
  if (!options.input || !options.ai || !options.output) {
    throw new Error(
      "Usage: render-release-notes.mjs --input <file> --ai <file> --output <file>",
    );
  }

  const input = JSON.parse(fs.readFileSync(options.input, "utf8"));
  const notes = JSON.parse(fs.readFileSync(options.ai, "utf8"));
  const rendered = renderReleaseNotes(input, notes);
  fs.writeFileSync(options.output, rendered);
  process.stdout.write(rendered);
}

const isMain = process.argv[1]
  && import.meta.url === pathToFileURL(path.resolve(process.argv[1])).href;

if (isMain) {
  try {
    main();
  } catch (error) {
    console.error(`render-release-notes: ${error.message}`);
    process.exitCode = 1;
  }
}
