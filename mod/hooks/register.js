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

/// A session started in the last 30 seconds is a real start; an older one means this module was
/// (re)loaded into a session that was already running.
const FRESH_START_MS = 30_000

/// The account a session started under. The Mod API gives a session no identity of its own
/// (`$.session.identity()` answers managed installs only), so the only identity source is the
/// global ~/.claude.json, which an account or organization switch rewrites under sessions that
/// are still running. A session therefore remembers what the file said at its real start and
/// writes nothing once the file disagrees. Anything that cannot be proven to be a real start
/// (a reload into a running session, a resumed session, an unreadable account, no start event)
/// leaves the session untrusted: it writes nothing until it is restarted.
export function createSessionBinding() {
  return { status: "unbound", hashes: null }
}

export async function bindSession($, binding) {
  try {
    const usage = await $.session.usage()
    const fresh = Number.isFinite(usage?.startedAt) && (await $.clock.now()) - usage.startedAt <= FRESH_START_MS
    const hashes = await readAccountHashes($, await readHome($))
    if (fresh && hashes.emailHash) {
      binding.status = "bound"
      binding.hashes = hashes
    } else {
      binding.status = "untrusted"
    }
  } catch {
    binding.status = "untrusted"
  }
}

function matchesBinding(binding, hashes) {
  if (!binding) return true
  return binding.status === "bound"
    && binding.hashes.emailHash === hashes.emailHash
    && binding.hashes.organizationHash === hashes.organizationHash
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
    await bindSession($, binding)
    return next(event)
  })
  on("session.measure", async ($, event, next) => {
    await recordMeasure($, binding).catch((error) => errorText(error))
    return next(event)
  })
}
