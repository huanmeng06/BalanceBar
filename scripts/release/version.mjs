#!/usr/bin/env node

import fs from "node:fs";
import path from "node:path";
import { pathToFileURL } from "node:url";

export const DEFAULT_PLIST_PATH = "work/balance-bar/Info.plist";

const BUMP_NAMES = new Set(["patch", "minor", "major"]);

function parseArguments(argv) {
  const options = {};

  for (let index = 0; index < argv.length; index += 1) {
    const argument = argv[index];
    if (!argument.startsWith("--")) {
      options._ ??= [];
      options._.push(argument);
      continue;
    }

    const key = argument.slice(2);
    const value = argv[index + 1];
    if (value === undefined || value.startsWith("--")) {
      options[key] = true;
    } else {
      options[key] = value;
      index += 1;
    }
  }

  return options;
}

export function parseSemver(version) {
  const match = /^(\d+)\.(\d+)\.(\d+)$/.exec(version.trim());
  if (!match) {
    throw new Error(`Unsupported version: ${version}`);
  }

  return {
    major: Number(match[1]),
    minor: Number(match[2]),
    patch: Number(match[3]),
  };
}

export function classifyVersionChange(previousVersion, currentVersion) {
  const previous = parseSemver(previousVersion);
  const current = parseSemver(currentVersion);

  if (
    current.major === previous.major
    && current.minor === previous.minor
    && current.patch === previous.patch
  ) {
    return null;
  }

  if (current.major === previous.major + 1) {
    if (current.minor === 0 && current.patch === 0) {
      return "major";
    }
    throw new Error(
      `Major version changes must reset minor and patch to zero: ${previousVersion} -> ${currentVersion}`,
    );
  }

  if (
    current.major === previous.major
    && current.minor === previous.minor + 1
  ) {
    if (current.patch === 0) {
      return "minor";
    }
    throw new Error(
      `Minor version changes must reset patch to zero: ${previousVersion} -> ${currentVersion}`,
    );
  }

  if (
    current.major === previous.major
    && current.minor === previous.minor
    && current.patch === previous.patch + 1
  ) {
    return "patch";
  }

  throw new Error(
    `Unsupported version change: ${previousVersion} -> ${currentVersion}. `
      + "Only a+1.0.0, a.b+1.0, or a.b.c+1 changes are released automatically.",
  );
}

function formatSemver(version) {
  return `${version.major}.${version.minor}.${version.patch}`;
}

function readPlistValue(plist, key) {
  const expression = new RegExp(
    `<key>${key}<\\/key>\\s*<string>([^<]+)<\\/string>`,
  );
  const match = expression.exec(plist);
  if (!match) {
    throw new Error(`Could not find ${key} in Info.plist`);
  }

  return match[1].trim();
}

export function readVersionFromPlistContent(plist) {
  const version = readPlistValue(plist, "CFBundleShortVersionString");
  const buildText = readPlistValue(plist, "CFBundleVersion");
  const build = Number(buildText);

  if (!Number.isInteger(build) || build < 0) {
    throw new Error(`CFBundleVersion must be a non-negative integer: ${buildText}`);
  }

  parseSemver(version);
  return { version, build };
}

export function readVersionFromPlist(plistPath = DEFAULT_PLIST_PATH) {
  return readVersionFromPlistContent(fs.readFileSync(plistPath, "utf8"));
}

export function planVersion({
  plistPath = DEFAULT_PLIST_PATH,
  bump,
}) {
  if (!BUMP_NAMES.has(bump)) {
    throw new Error(`Bump must be one of patch, minor, major: ${bump}`);
  }

  const current = readVersionFromPlist(plistPath);
  const next = parseSemver(current.version);

  if (bump === "major") {
    next.major += 1;
    next.minor = 0;
    next.patch = 0;
  } else if (bump === "minor") {
    next.minor += 1;
    next.patch = 0;
  } else {
    next.patch += 1;
  }

  const version = formatSemver(next);
  const prerelease = bump === "patch";
  const tag = `v${version}`;

  return {
    bump,
    currentVersion: current.version,
    currentBuild: current.build,
    version,
    build: current.build + 1,
    prerelease,
    tag,
  };
}

export function planVersionFromChange({
  previousVersion,
  currentVersion,
  currentBuild,
}) {
  const bump = classifyVersionChange(previousVersion, currentVersion);
  if (!bump) {
    throw new Error(`No version change detected: ${currentVersion}`);
  }

  if (!Number.isInteger(currentBuild) || currentBuild < 0) {
    throw new Error(`CFBundleVersion must be a non-negative integer: ${currentBuild}`);
  }

  const prerelease = bump === "patch";
  const tag = `v${currentVersion}`;

  return {
    bump,
    previousVersion,
    currentVersion,
    version: currentVersion,
    build: currentBuild,
    prerelease,
    tag,
  };
}

export function updatePlist(plistPath, plan) {
  const original = fs.readFileSync(plistPath, "utf8");
  const replacements = [
    ["CFBundleShortVersionString", plan.version],
    ["CFBundleVersion", String(plan.build)],
  ];
  let updated = original;

  for (const [key, value] of replacements) {
    const expression = new RegExp(
      `(<key>${key}<\\/key>\\s*<string>)([^<]+)(<\\/string>)`,
    );
    const next = updated.replace(expression, `$1${value}$3`);
    if (next === updated) {
      throw new Error(`Could not update ${key} in ${plistPath}`);
    }
    updated = next;
  }

  fs.writeFileSync(plistPath, updated);
  return updated;
}

function writeGithubOutput(plan, outputPath) {
  if (!outputPath) {
    return;
  }

  const values = {
    bump: plan.bump,
    previous_version: plan.previousVersion ?? plan.currentVersion,
    current_version: plan.currentVersion,
    current_build: plan.currentBuild ?? plan.build,
    version: plan.version,
    build: plan.build,
    prerelease: String(plan.prerelease),
    tag: plan.tag,
  };

  const content = Object.entries(values)
    .map(([key, value]) => `${key}=${value}`)
    .join("\n");
  fs.appendFileSync(outputPath, `${content}\n`);
}

function main() {
  const [command, ...rest] = process.argv.slice(2);
  const options = parseArguments(rest);
  const plistPath = options.plist ?? DEFAULT_PLIST_PATH;
  const bump = options.bump ?? process.env.RELEASE_BUMP;

  if (command !== "plan" && command !== "plan-existing" && command !== "bump") {
    throw new Error(
      "Usage: version.mjs <plan|bump> --bump <patch|minor|major> "
        + "or version.mjs plan-existing --previous-version <version> "
        + "--current-version <version> --current-build <number>",
    );
  }

  const plan = command === "plan-existing"
    ? planVersionFromChange({
      previousVersion: options["previous-version"],
      currentVersion: options["current-version"],
      currentBuild: Number(options["current-build"]),
    })
    : planVersion({
      plistPath,
      bump,
    });

  if (command === "bump") {
    updatePlist(plistPath, plan);
  }

  writeGithubOutput(plan, options.output ?? process.env.GITHUB_OUTPUT);
  process.stdout.write(`${JSON.stringify(plan, null, 2)}\n`);
}

const isMain = process.argv[1]
  && import.meta.url === pathToFileURL(path.resolve(process.argv[1])).href;

if (isMain) {
  try {
    main();
  } catch (error) {
    console.error(`release-version: ${error.message}`);
    process.exitCode = 1;
  }
}
