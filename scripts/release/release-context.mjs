#!/usr/bin/env node

import fs from "node:fs";
import path from "node:path";
import { execFileSync } from "node:child_process";
import { pathToFileURL } from "node:url";
import {
  classifyVersionChange,
  readVersionFromPlistContent,
} from "./version.mjs";

export const DEFAULT_PLIST_PATH = "work/balance-bar/Info.plist";

function gitOutput(argumentsList) {
  return execFileSync("git", argumentsList, { encoding: "utf8" }).trim();
}

export function readVersionAtCommit(commit, plistPath = DEFAULT_PLIST_PATH) {
  const plist = execFileSync(
    "git",
    ["show", `${commit}:${plistPath}`],
    { encoding: "utf8" },
  );
  return readVersionFromPlistContent(plist);
}

export function buildReleaseContext({
  event,
  mergeSha,
  parentSha,
  previous,
  current,
}) {
  const pullRequest = event?.pull_request;
  if (!pullRequest || pullRequest.merged !== true) {
    throw new Error("This workflow only handles merged pull requests");
  }

  if (!mergeSha) {
    throw new Error("Could not determine the merge commit SHA");
  }

  const changed = previous.version !== current.version;
  const values = {
    should_release: String(changed),
    pr_number: pullRequest.number,
    pr_url: pullRequest.html_url,
    merge_sha: mergeSha,
    parent_sha: parentSha,
    previous_version: previous.version,
    previous_build: previous.build,
    version: current.version,
    build: current.build,
  };

  if (!changed) {
    return values;
  }

  values.bump = classifyVersionChange(previous.version, current.version);
  return values;
}

function writeGithubOutput(values, outputPath) {
  if (!outputPath) {
    return;
  }

  const content = Object.entries(values)
    .map(([key, value]) => `${key}=${value}`)
    .join("\n");
  fs.appendFileSync(outputPath, `${content}\n`);
}

function main() {
  const eventPath = process.env.GITHUB_EVENT_PATH;
  if (!eventPath) {
    throw new Error("GITHUB_EVENT_PATH is required");
  }

  const event = JSON.parse(fs.readFileSync(eventPath, "utf8"));
  const pullRequest = event.pull_request;
  if (!pullRequest || pullRequest.merged !== true) {
    throw new Error("This workflow only handles merged pull requests");
  }

  const mergeSha = pullRequest.merge_commit_sha || process.env.GITHUB_SHA;
  if (!mergeSha) {
    throw new Error("Could not determine the merge commit SHA");
  }

  const parentSha = gitOutput(["rev-parse", `${mergeSha}^`]);
  const previous = readVersionAtCommit(parentSha);
  const current = readVersionAtCommit(mergeSha);

  const values = buildReleaseContext({
    event,
    mergeSha,
    parentSha,
    previous,
    current,
  });

  writeGithubOutput(values, process.env.GITHUB_OUTPUT);
  process.stdout.write(`${JSON.stringify(values, null, 2)}\n`);
}

const isMain = process.argv[1]
  && import.meta.url === pathToFileURL(path.resolve(process.argv[1])).href;

if (isMain) {
  try {
    main();
  } catch (error) {
    console.error(`release-context: ${error.message}`);
    process.exitCode = 1;
  }
}
