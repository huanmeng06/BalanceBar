#!/usr/bin/env node

import fs from "node:fs";
import path from "node:path";
import { pathToFileURL } from "node:url";

import { verifyReleaseNotesInventory } from "./build-release-notes-assets.mjs";

function parseArguments(argv) {
  const options = {};
  for (let index = 0; index < argv.length; index += 1) {
    const key = argv[index];
    if (!key.startsWith("--")) continue;
    options[key.slice(2)] = argv[index + 1];
    index += 1;
  }
  return options;
}

function main() {
  const options = parseArguments(process.argv.slice(2));
  if (!options.input || !options.manifest || !options.release) {
    throw new Error(
      "Usage: verify-release-notes-assets.mjs --input <file> --manifest <file> --release <release-json>",
    );
  }
  const input = JSON.parse(fs.readFileSync(options.input, "utf8"));
  const manifestData = fs.readFileSync(options.manifest);
  const manifest = JSON.parse(manifestData.toString("utf8"));
  const release = JSON.parse(fs.readFileSync(options.release, "utf8"));
  verifyReleaseNotesInventory({
    input,
    manifest,
    manifestData,
    releaseAssets: release.assets,
  });
  process.stdout.write("release notes asset inventory: PASS\n");
}

const isMain = process.argv[1]
  && import.meta.url === pathToFileURL(path.resolve(process.argv[1])).href;

if (isMain) {
  try {
    main();
  } catch (error) {
    console.error(`verify-release-notes-assets: ${error.message}`);
    process.exitCode = 1;
  }
}
