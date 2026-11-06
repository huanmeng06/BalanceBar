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

/// A first load into a session that started in the last 30 seconds is taken as the session's real
/// start. `usage().startedAt` is the session's first launch, so a resumed or forked session looks
/// old however recently its process started. Such a session is recognised by two things at start
/// that a Mod added to a running session never shows together: no API response yet in this
/// process (`rateLimits` empty) and a cost already carried over from the earlier run
/// (`cost.usd > 0`, which a new session starts without). A session that has had a response, or has
/// no carried-over cost, stays untrusted.
const FRESH_START_MS = 30_000

/// The account a session started under. The Mod API gives a session no identity of its own
/// (`$.session.identity()` answers managed installs only), so the only identity source is the
/// global ~/.claude.json, which an account or organization switch rewrites under sessions that
/// are still running. A session therefore remembers what the file said when this module first
/// loaded into it, in `$.state`: that survives a reload of the module, so a reload never binds
/// again, whatever the session's age. It then writes nothing once the file disagrees. Anything
/// that cannot be proven to be a real start (added to a running session, an unreadable account,
/// no start event) leaves the session untrusted: it writes nothing until it is restarted.
/// A resumed or forked session binds like a new one, to the account the file names at that moment.
export async function bindSession($) {
  try {
    const held = await $.state.get({ plugin: "balancebar-mod", key: "session" })
    if (held.value) return
    let session = { status: "untrusted", emailHash: null, organizationHash: null }
    try {
      const usage = await $.session.usage()
      const newSession = Number.isFinite(usage?.startedAt) && (await $.clock.now()) - usage.startedAt <= FRESH_START_MS
      const resumedAtStart = Array.isArray(usage?.rateLimits) && usage.rateLimits.length === 0
        && Number.isFinite(usage?.cost?.usd) && usage.cost.usd > 0
      const fresh = newSession || resumedAtStart
      const hashes = await readAccountHashes($, await readHome($))
      if (fresh && hashes.emailHash) session = { status: "bound", ...hashes }
    } catch {
      // stays untrusted
    }
    await $.state.set({ plugin: "balancebar-mod", key: "session" }, session, { ifVersion: held.version })
  } catch {
    // no state: measures find no binding and write nothing
  }
}

async function matchesBinding($, hashes) {
  const { value } = await $.state.get({ plugin: "balancebar-mod", key: "session" })
  return value?.status === "bound"
    && value.emailHash === hashes.emailHash
    && value.organizationHash === hashes.organizationHash
}

/// Capability detection: a missing usage() throws and is treated as "write nothing".
/// `enforceBinding` is on in the real hook; the pure-mapping tests leave it off.
export async function recordMeasure($, enforceBinding = false) {
  try {
    const usage = await $.session.usage()
    const home = await readHome($)
    const hashes = await readAccountHashes($, home)
    if (enforceBinding && !(await matchesBinding($, hashes))) return false
    const { emailHash, organizationHash } = hashes
    const snapshot = buildSnapshot({ now: new Date().toISOString(), usage, emailHash, organizationHash })
    if (!snapshot) return false
    return await writeSnapshot($, snapshot, snapshotFilename(emailHash, organizationHash))
  } catch {
    return false
  }
}

export function register(on) {
  on("session.start", async ($, event, next) => {
    await bindSession($)
    return next(event)
  })
  on("session.measure", async ($, event, next) => {
    await recordMeasure($, true).catch((error) => errorText(error))
    return next(event)
  })
}
