import {
  buildSnapshot,
  errorText,
  extractEmail,
  extractOrganization,
  hashEmail,
  inboxCandidates,
  snapshotFilename,
} from "./snapshot.js"

function text(value) {
  return typeof value === "string" && value ? value : undefined
}

async function readHome($) {
  try {
    return text(await $.env.get("HOME"))
  } catch {
    return undefined
  }
}

async function readConfiguredInbox($) {
  try {
    return text(await $.env.get("BALANCEBAR_MOD_INBOX"))
  } catch {
    return undefined
  }
}

/// Re-read on every observation so an account switch is never attributed to the old account.
async function readAccountHashes($, home) {
  try {
    if (!home) return { emailHash: null, organizationHash: null }
    const text = await $.fs.read(`${home.replace(/\/$/, "")}/.claude.json`)
    const email = extractEmail(text)
    const organization = extractOrganization(text)
    return {
      emailHash: email ? await hashEmail(email) : null,
      organizationHash: organization ? await hashEmail(organization) : null,
    }
  } catch {
    return { emailHash: null, organizationHash: null }
  }
}

/// Writes into the first existing inbox directory. The directory is never created.
export async function writeSnapshot($, snapshot, filename) {
  const home = await readHome($)
  const configured = await readConfiguredInbox($)
  const payload = `${JSON.stringify(snapshot, null, 2)}\n`
  for (const directory of inboxCandidates({ home, configured })) {
    try {
      if (!(await $.fs.exists(directory))) continue
      await $.fs.write(`${directory.replace(/\/$/, "")}/${filename}`, payload)
      return true
    } catch {
      continue
    }
  }
  return false
}

/// The account a session started under. The Mod API gives a session no identity of its own
/// (`$.session.identity()` answers only managed installs), so the only identity source is the
/// global ~/.claude.json, which an account or organization switch rewrites under sessions that
/// are still running. A session therefore remembers what the file said when it first measured
/// and writes nothing once the file disagrees: its usage can no longer be proven to belong to
/// the account the file now names.
export function createSessionBinding() {
  return { bound: null }
}

function matchesBinding(binding, hashes) {
  if (!binding) return true
  if (!binding.bound) {
    // Only an identified account can be bound; an unidentified one is rejected downstream.
    if (hashes.emailHash) binding.bound = hashes
    return true
  }
  return binding.bound.emailHash === hashes.emailHash
    && binding.bound.organizationHash === hashes.organizationHash
}

/// Capability detection: a missing usage() throws and is treated as "write nothing".
export async function recordMeasure($, binding = null) {
  try {
    const usage = await $.session.usage()
    const home = await readHome($)
    const hashes = await readAccountHashes($, home)
    if (!matchesBinding(binding, hashes)) return false
    const { emailHash, organizationHash } = hashes
    const snapshot = buildSnapshot({ now: new Date().toISOString(), usage, emailHash, organizationHash })
    if (!snapshot) return false
    return await writeSnapshot($, snapshot, snapshotFilename(emailHash, organizationHash))
  } catch {
    return false
  }
}

export function register(on) {
  const binding = createSessionBinding()
  on("session.start", async ($, event, next) => {
    // Bind at session start, before any switch can happen under a running session.
    const home = await readHome($)
    matchesBinding(binding, await readAccountHashes($, home))
    return next(event)
  })
  on("session.measure", async ($, event, next) => {
    await recordMeasure($, binding).catch((error) => errorText(error))
    return next(event)
  })
}
