import { createHash } from "node:crypto";
import { execFileSync } from "node:child_process";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const maximumManifestBytes = 16 * 1024;
const maximumSignatureBytes = 4 * 1024;
const repositoryRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../..");

function argument(name, required = true) {
  const index = process.argv.indexOf(name);
  if (index === -1 || index + 1 >= process.argv.length) {
    if (!required) return undefined;
    throw new Error(`Missing ${name}`);
  }
  return process.argv[index + 1];
}

function sha256(filePath) {
  return createHash("sha256").update(fs.readFileSync(filePath)).digest("hex");
}

function readSigningKeys(plistPath) {
  const plist = fs.readFileSync(plistPath, "utf8");
  const match = plist.match(/<key>BalanceBarUpdateSigningKeys<\/key>\s*<array>([\s\S]*?)<\/array>/);
  if (!match) throw new Error("Info.plist has no BalanceBarUpdateSigningKeys array");
  const keys = [...match[1].matchAll(/<dict>([\s\S]*?)<\/dict>/g)].map(([, entry]) => {
    const keyId = entry.match(/<key>keyId<\/key>\s*<string>([^<]+)<\/string>/)?.[1];
    const publicKey = entry.match(/<key>publicKey<\/key>\s*<string>([^<]+)<\/string>/)?.[1];
    return { keyId, publicKey };
  });
  if (keys.some(({ keyId, publicKey }) => !keyId || !publicKey)) {
    throw new Error("Info.plist contains a malformed update signing key");
  }
  return keys;
}

function validateManifest(manifest, bytes) {
  if (bytes.length > maximumManifestBytes) throw new Error("Manifest exceeds 16 KB");
  if (manifest.schema !== 1) throw new Error("Unsupported manifest schema");
  if (manifest.bundleIdentifier !== "com.huanmeng06.BalanceBar.app") throw new Error("Invalid bundleIdentifier");
  if (typeof manifest.version !== "string" || !/^\d+\.\d+\.\d+$/.test(manifest.version)) throw new Error("Invalid version");
  if (!['stable', 'beta'].includes(manifest.channel)) throw new Error("Invalid channel");
  if (manifest.tag !== `v${manifest.version}`) throw new Error("Tag does not match version");
  if (manifest.asset?.name !== `BalanceBar-${manifest.version}.dmg`) throw new Error("Invalid asset name");
  if (!Number.isSafeInteger(manifest.asset?.size) || manifest.asset.size < 0) throw new Error("Invalid asset size");
  if (typeof manifest.asset?.sha256 !== "string" || !/^[0-9a-f]{64}$/.test(manifest.asset.sha256)) throw new Error("Invalid asset SHA-256");
  if (manifest.source?.repository !== "huanmeng06/BalanceBar") throw new Error("Invalid source repository");
  if (typeof manifest.source?.commit !== "string" || !/^[0-9a-f]{40}$/.test(manifest.source.commit)) throw new Error("Invalid source commit");
  if (typeof manifest.source?.runId !== "string" || !/^\d+$/.test(manifest.source.runId)) throw new Error("Invalid source runId");
  if (typeof manifest.source?.runAttempt !== "string" || !/^\d+$/.test(manifest.source.runAttempt)) throw new Error("Invalid source runAttempt");
  if (typeof manifest.signedAt !== "string" || !/^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ$/.test(manifest.signedAt) || Number.isNaN(Date.parse(manifest.signedAt))) {
    throw new Error("Invalid signedAt timestamp");
  }
}

function createManifest() {
  const dmgPath = argument("--dmg");
  const version = argument("--version");
  const tag = argument("--tag");
  const channel = argument("--channel");
  const commit = argument("--commit");
  const runId = argument("--run-id");
  const runAttempt = argument("--run-attempt");
  const outputPath = argument("--output");
  const manifest = {
    schema: 1,
    bundleIdentifier: "com.huanmeng06.BalanceBar.app",
    version,
    channel,
    tag,
    asset: {
      name: path.basename(dmgPath),
      size: fs.statSync(dmgPath).size,
      sha256: sha256(dmgPath),
    },
    source: {
      repository: "huanmeng06/BalanceBar",
      commit,
      runId,
      runAttempt,
    },
    signedAt: new Date().toISOString().replace(/\.\d{3}Z$/, "Z"),
  };
  const bytes = Buffer.from(`${JSON.stringify(manifest)}\n`, "utf8");
  validateManifest(manifest, bytes);
  fs.writeFileSync(outputPath, bytes, { mode: 0o600 });
}

function signManifest() {
  const manifestPath = argument("--manifest");
  const privateKeyPath = argument("--private-key");
  const outputPath = argument("--output");
  const plistPath = argument("--plist", false);
  let keyId = argument("--key-id", false);
  const bytes = fs.readFileSync(manifestPath);
  const manifest = JSON.parse(bytes.toString("utf8"));
  validateManifest(manifest, bytes);
  if (plistPath) {
    const publicDER = execFileSync("openssl", ["pkey", "-in", privateKeyPath, "-pubout", "-outform", "DER"]);
    const publicKey = publicDER.subarray(-32).toString("base64");
    const matchingKey = readSigningKeys(plistPath).find((entry) => entry.publicKey === publicKey);
    if (!matchingKey) throw new Error("Signing private key does not match a trusted Info.plist public key");
    keyId = matchingKey.keyId;
  }
  if (!keyId) throw new Error("A signing keyId or trusted Info.plist is required");
  const signaturePath = `${outputPath}.raw`;
  try {
    execFileSync("openssl", ["pkeyutl", "-sign", "-inkey", privateKeyPath, "-rawin", "-in", manifestPath, "-out", signaturePath], { stdio: "pipe" });
    const signature = fs.readFileSync(signaturePath);
    if (signature.length !== 64) throw new Error("Ed25519 signature must be 64 bytes");
    const signatureJSON = Buffer.from(`${JSON.stringify({ schema: 1, algorithm: "ed25519", keyId, signature: signature.toString("base64") })}\n`);
    if (signatureJSON.length > maximumSignatureBytes) throw new Error("Signature file exceeds 4 KB");
    fs.writeFileSync(outputPath, signatureJSON, { mode: 0o600 });
  } finally {
    fs.rmSync(signaturePath, { force: true });
  }
}

function verifyManifest() {
  const manifestPath = argument("--manifest");
  const signaturePath = argument("--signature");
  const plistPath = argument("--plist", false);
  const publicKeyOverride = argument("--public-key-base64", false);
  const dmgPath = argument("--dmg", false);
  const bytes = fs.readFileSync(manifestPath);
  const signatureBytes = fs.readFileSync(signaturePath);
  if (signatureBytes.length > maximumSignatureBytes) throw new Error("Signature file exceeds 4 KB");
  const manifest = JSON.parse(bytes.toString("utf8"));
  const signature = JSON.parse(signatureBytes.toString("utf8"));
  validateManifest(manifest, bytes);
  if (signature.schema !== 1 || signature.algorithm !== "ed25519" || typeof signature.keyId !== "string") {
    throw new Error("Invalid signature metadata");
  }
  const rawSignature = Buffer.from(signature.signature ?? "", "base64");
  if (rawSignature.length !== 64 || rawSignature.toString("base64") !== signature.signature) throw new Error("Invalid base64 Ed25519 signature");
  let publicKey = publicKeyOverride;
  if (plistPath) {
    const key = readSigningKeys(plistPath).find((entry) => entry.keyId === signature.keyId);
    if (!key) throw new Error(`No trusted public key for keyId ${signature.keyId}`);
    publicKey = key.publicKey;
  }
  if (!publicKey) throw new Error("A trusted public key or Info.plist is required");
  const rawPublicKey = Buffer.from(publicKey, "base64");
  if (rawPublicKey.length !== 32 || rawPublicKey.toString("base64") !== publicKey) throw new Error("Invalid raw Ed25519 public key");
  const temporaryDirectory = fs.mkdtempSync(path.join(process.env.TMPDIR ?? "/tmp", "balancebar-verify-"));
  const publicDERPath = path.join(temporaryDirectory, "public.der");
  const signatureDERPath = path.join(temporaryDirectory, "signature.bin");
  try {
    fs.writeFileSync(publicDERPath, Buffer.concat([Buffer.from("302a300506032b6570032100", "hex"), rawPublicKey]));
    fs.writeFileSync(signatureDERPath, rawSignature);
    execFileSync("openssl", ["pkeyutl", "-verify", "-pubin", "-inkey", publicDERPath, "-keyform", "DER", "-rawin", "-in", manifestPath, "-sigfile", signatureDERPath], { stdio: "pipe" });
  } finally {
    fs.rmSync(temporaryDirectory, { recursive: true, force: true });
  }
  if (dmgPath) {
    if (path.basename(dmgPath) !== manifest.asset.name) throw new Error("DMG filename does not match manifest");
    if (fs.statSync(dmgPath).size !== manifest.asset.size) throw new Error("DMG size does not match manifest");
    if (sha256(dmgPath) !== manifest.asset.sha256) throw new Error("DMG SHA-256 does not match manifest");
  }
  process.stdout.write(`Verified ${manifest.tag} update manifest (${signature.keyId})\n`);
}

try {
  const command = process.argv[2];
  if (command === "create") createManifest();
  else if (command === "sign") signManifest();
  else if (command === "verify") verifyManifest();
  else throw new Error("Usage: update-manifest.mjs create|sign|verify [options]");
} catch (error) {
  process.stderr.write(`update-manifest: ${error.message}\n`);
  process.exitCode = 1;
}
