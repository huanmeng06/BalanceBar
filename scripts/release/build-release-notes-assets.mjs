#!/usr/bin/env node

import crypto from "node:crypto";
import fs from "node:fs";
import path from "node:path";
import { pathToFileURL } from "node:url";

import {
  RELEASE_NOTES_LOCALES,
  renderLocalizedReleaseNotes,
} from "./render-release-notes.mjs";
import {
  requestLocalizedReleaseNotes,
} from "./generate-release-notes.mjs";

export const REMOTE_RELEASE_NOTES_SCHEMA_VERSION = 1;
export const REMOTE_RELEASE_NOTES_MAX_BYTES = 256 * 1024;

function normalizedSHA256(value) {
  const digest = String(value || "").replace(/^sha256:/i, "");
  if (!/^[0-9a-f]{64}$/i.test(digest)) {
    throw new Error(`invalid SHA-256 digest: ${value}`);
  }
  return digest.toLowerCase();
}

function sha256(data) {
  return crypto.createHash("sha256").update(data).digest("hex");
}

function validateMarkdown(markdown, locale) {
  if (typeof markdown !== "string" || !markdown.trim()) {
    throw new Error(`${locale} release notes must be non-empty`);
  }
  const data = Buffer.from(markdown, "utf8");
  if (data.length > REMOTE_RELEASE_NOTES_MAX_BYTES) {
    throw new Error(`${locale} release notes exceed ${REMOTE_RELEASE_NOTES_MAX_BYTES} bytes`);
  }
  if (/[\u0000-\u0008\u000B\u000C\u000E-\u001F\u007F]/u.test(markdown)) {
    throw new Error(`${locale} release notes contain control characters`);
  }
  if (/<[^>\n]*>|<!--|-->/u.test(markdown)) {
    throw new Error(`${locale} release notes contain raw HTML`);
  }
  if (/!\[/u.test(markdown)) {
    throw new Error(`${locale} release notes contain an image`);
  }

  const linkPattern = /\[[^\]\n]*\]\(([^)\s]+)(?:\s+[^)]*)?\)/gu;
  for (const match of markdown.matchAll(linkPattern)) {
    const url = new URL(match[1]);
    if (!/^https?:$/i.test(url.protocol) || !url.hostname || url.username || url.password) {
      throw new Error(`${locale} release notes contain an unsafe link`);
    }
  }
  return markdown.trim();
}

function assetName(version, locale) {
  if (locale === "manifest") {
    return `BalanceBar-release-notes-${version}-manifest.json`;
  }
  if (!RELEASE_NOTES_LOCALES.includes(locale)) {
    throw new Error(`unsupported release notes locale: ${locale}`);
  }
  return `BalanceBar-release-notes-${version}-${locale}.md`;
}

function assertSafeAssetName(name, expected) {
  if (name !== expected || name.includes("/") || name.includes("\\") || name.includes("..")) {
    throw new Error(`invalid release notes asset name: ${name}`);
  }
}

function assertLocalizedCoverage(canonicalNotes, localizedNotes) {
  const actualLocales = Object.keys(localizedNotes || {}).sort();
  const expectedLocales = [...RELEASE_NOTES_LOCALES].sort();
  if (JSON.stringify(actualLocales) !== JSON.stringify(expectedLocales)) {
    throw new Error("localized release notes must cover exactly the eight supported locales");
  }
  for (const locale of RELEASE_NOTES_LOCALES) {
    const translated = localizedNotes[locale];
    for (const section of ["features", "fixes"]) {
      const canonicalItems = canonicalNotes?.[section];
      const translatedItems = translated?.[section];
      if (!Array.isArray(canonicalItems) || !Array.isArray(translatedItems) ||
          canonicalItems.length !== translatedItems.length) {
        throw new Error(`${locale}.${section} does not preserve canonical coverage`);
      }
      translatedItems.forEach((item, index) => {
        const sourceSignature = (sources) => JSON.stringify(
          (sources || []).map((source) => ({ kind: source.kind, number: source.number })),
        );
        if (sourceSignature(item.sources) !== sourceSignature(canonicalItems[index].sources)) {
          throw new Error(`${locale}.${section}[${index}] changed canonical sources`);
        }
      });
    }
  }
}

export function buildReleaseNotesAssetBundle({
  input,
  canonicalNotes,
  localizedNotes,
  outputDir,
}) {
  if (!input?.version || !/^\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?(?:\+[0-9A-Za-z.-]+)?$/.test(input.version)) {
    throw new Error(`invalid release notes version: ${input?.version}`);
  }
  if (!outputDir) throw new Error("outputDir is required");

  const resolvedTranslations = localizedNotes || Object.fromEntries(
    RELEASE_NOTES_LOCALES.map((locale) => [locale, canonicalNotes]),
  );
  assertLocalizedCoverage(canonicalNotes, resolvedTranslations);
  fs.mkdirSync(outputDir, { recursive: true });

  const locales = {};
  const files = [];
  for (const locale of RELEASE_NOTES_LOCALES) {
    const name = assetName(input.version, locale);
    assertSafeAssetName(name, name);
    const markdown = validateMarkdown(
      renderLocalizedReleaseNotes(input, canonicalNotes, locale, resolvedTranslations[locale]),
      locale,
    );
    const data = Buffer.from(`${markdown}\n`, "utf8");
    if (data.length > REMOTE_RELEASE_NOTES_MAX_BYTES) {
      throw new Error(`${locale} release notes exceed ${REMOTE_RELEASE_NOTES_MAX_BYTES} bytes`);
    }
    const filePath = path.join(outputDir, name);
    fs.writeFileSync(filePath, data, { flag: "w" });
    const digest = sha256(data);
    locales[locale] = { asset: name, size: data.length, sha256: digest };
    files.push({ locale, name, path: filePath, size: data.length, sha256: digest });
  }

  const manifest = {
    schemaVersion: REMOTE_RELEASE_NOTES_SCHEMA_VERSION,
    version: input.version,
    locales,
  };
  const manifestName = assetName(input.version, "manifest");
  assertSafeAssetName(manifestName, manifestName);
  const manifestData = Buffer.from(`${JSON.stringify(manifest, null, 2)}\n`, "utf8");
  if (manifestData.length > REMOTE_RELEASE_NOTES_MAX_BYTES) {
    throw new Error("release notes manifest is too large");
  }
  const manifestPath = path.join(outputDir, manifestName);
  fs.writeFileSync(manifestPath, manifestData, { flag: "w" });

  const expectedNames = new Set([manifestName, ...files.map((file) => file.name)]);
  const actualNames = fs.readdirSync(outputDir).filter((name) => !name.startsWith("."));
  if (actualNames.length !== expectedNames.size || actualNames.some((name) => !expectedNames.has(name))) {
    throw new Error("release notes output contains an unexpected asset");
  }

  return {
    manifest,
    manifestName,
    manifestPath,
    files,
    assetPaths: [manifestPath, ...files.map((file) => file.path)],
  };
}

export function verifyReleaseNotesInventory({ input, manifest, manifestData, releaseAssets }) {
  if (!input?.version || !manifest || !Array.isArray(releaseAssets)) {
    throw new Error("input, manifest, and releaseAssets are required");
  }
  if (manifest.schemaVersion !== REMOTE_RELEASE_NOTES_SCHEMA_VERSION ||
      manifest.version !== input.version) {
    throw new Error("published Release notes manifest has the wrong schema or version");
  }
  const actualLocales = Object.keys(manifest.locales || {}).sort();
  const expectedLocales = [...RELEASE_NOTES_LOCALES].sort();
  if (JSON.stringify(actualLocales) !== JSON.stringify(expectedLocales)) {
    throw new Error("published Release notes manifest does not contain exactly the supported locales");
  }
  const expectedNames = [
    `BalanceBar-${input.version}.dmg`,
    assetName(input.version, "manifest"),
    ...RELEASE_NOTES_LOCALES.map((locale) => assetName(input.version, locale)),
  ].sort();
  const actualNames = releaseAssets.map((asset) => asset.name).sort();
  if (JSON.stringify(actualNames) !== JSON.stringify(expectedNames)) {
    throw new Error("published Release asset inventory does not match the DMG plus notes contract");
  }
  for (const locale of RELEASE_NOTES_LOCALES) {
    const expected = manifest.locales?.[locale];
    const actual = releaseAssets.find((asset) => asset.name === expected?.asset);
    if (!expected || expected.asset !== assetName(input.version, locale) ||
        !Number.isInteger(expected.size) || expected.size <= 0 ||
        expected.size > REMOTE_RELEASE_NOTES_MAX_BYTES ||
        !normalizedSHA256(expected.sha256) || !actual || actual.size !== expected.size ||
        normalizedSHA256(actual.digest) !== normalizedSHA256(expected.sha256)) {
      throw new Error(`published Release asset failed verification for ${locale}`);
    }
  }
  const manifestAsset = releaseAssets.find((asset) => asset.name === assetName(input.version, "manifest"));
  if (!manifestAsset || !Number.isInteger(manifestAsset.size) ||
      manifestAsset.size <= 0 || manifestAsset.size > REMOTE_RELEASE_NOTES_MAX_BYTES ||
      !normalizedSHA256(manifestAsset.digest)) {
    throw new Error("published Release manifest asset has no verifiable size/digest");
  }
  if (manifestData) {
    const data = Buffer.isBuffer(manifestData) ? manifestData : Buffer.from(manifestData);
    if (manifestAsset.size !== data.length ||
        normalizedSHA256(manifestAsset.digest) !== sha256(data)) {
      throw new Error("published Release manifest digest does not match the generated manifest");
    }
  }
  return true;
}

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

async function main() {
  const options = parseArguments(process.argv.slice(2));
  if (!options.input || !options.ai || !options["output-dir"]) {
    throw new Error(
      "Usage: build-release-notes-assets.mjs --input <file> --ai <file> --output-dir <directory> [--translations <file>]",
    );
  }
  const input = JSON.parse(fs.readFileSync(options.input, "utf8"));
  const canonicalNotes = JSON.parse(fs.readFileSync(options.ai, "utf8"));
  const localizedNotes = options.translations
    ? JSON.parse(fs.readFileSync(options.translations, "utf8"))
    : await requestLocalizedReleaseNotes(input, canonicalNotes);
  const result = buildReleaseNotesAssetBundle({
    input,
    canonicalNotes,
    localizedNotes,
    outputDir: options["output-dir"],
  });
  process.stdout.write(`${JSON.stringify({
    manifest: result.manifestPath,
    assets: result.assetPaths,
  }, null, 2)}\n`);
}

const isMain = process.argv[1]
  && import.meta.url === pathToFileURL(path.resolve(process.argv[1])).href;

if (isMain) {
  main().catch((error) => {
    console.error(`build-release-notes-assets: ${error.message}`);
    process.exitCode = 1;
  });
}
