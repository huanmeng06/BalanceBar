#!/usr/bin/env node

import fs from "node:fs";
import path from "node:path";
import { pathToFileURL } from "node:url";

import { parseSemver } from "./version.mjs";

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

function readJson(filePath) {
  if (!filePath) {
    throw new Error("A releases JSON file is required");
  }
  return JSON.parse(fs.readFileSync(filePath, "utf8"));
}

function parseBoolean(value, fieldName) {
  if (value === true || value === "true") {
    return true;
  }
  if (value === false || value === "false") {
    return false;
  }
  throw new Error(`${fieldName} must be true or false`);
}

export function compareSemver(left, right) {
  const leftVersion = typeof left === "string" ? parseSemver(left) : left;
  const rightVersion = typeof right === "string" ? parseSemver(right) : right;

  for (const component of ["major", "minor", "patch"]) {
    if (leftVersion[component] !== rightVersion[component]) {
      return leftVersion[component] - rightVersion[component];
    }
  }
  return 0;
}

export function versionFromTag(tagName) {
  if (typeof tagName !== "string") {
    return null;
  }

  const match = /^v?(\d+\.\d+\.\d+)$/.exec(tagName.trim());
  return match ? match[1] : null;
}

function normaliseRelease(release) {
  const version = versionFromTag(release?.tagName);
  if (!version || release?.isDraft === true || release?.isDraft === "true") {
    return null;
  }

  return {
    ...release,
    version,
    isPrerelease: release.isPrerelease === true || release.isPrerelease === "true",
  };
}

/**
 * Select the release used as the lower bound for a new release comparison.
 *
 * Patch releases are Pre-releases in this repository, so they compare only
 * against the immediately preceding release in the version sequence. Stable
 * minor/major releases compare against the immediately preceding Stable
 * release, intentionally including all Pre-release work since that baseline.
 */
export function selectPreviousRelease({ releases = [], currentVersion, prerelease }) {
  const current = parseSemver(currentVersion);
  const eligible = releases
    .map(normaliseRelease)
    .filter(Boolean)
    .filter((release) => compareSemver(release.version, current) < 0)
    .filter((release) => prerelease || !release.isPrerelease)
    .sort((left, right) => {
      const versionOrder = compareSemver(right.version, left.version);
      if (versionOrder !== 0) {
        return versionOrder;
      }
      return right.tagName.localeCompare(left.tagName);
    });

  return eligible[0] ?? null;
}

function main() {
  const options = parseArguments(process.argv.slice(2));
  const releases = readJson(options.releases);
  if (!Array.isArray(releases)) {
    throw new Error("Releases JSON must be an array");
  }

  const previous = selectPreviousRelease({
    releases,
    currentVersion: options["current-version"],
    prerelease: parseBoolean(options.prerelease, "--prerelease"),
  });

  if (previous) {
    process.stdout.write(`${previous.tagName}\n`);
  }
}

const isMain = process.argv[1]
  && import.meta.url === pathToFileURL(path.resolve(process.argv[1])).href;

if (isMain) {
  try {
    main();
  } catch (error) {
    console.error(`select-previous-release: ${error.message}`);
    process.exitCode = 1;
  }
}
