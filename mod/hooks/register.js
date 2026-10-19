import {
  buildSnapshot,
  errorText,
  extractEmail,
  hashEmail,
  inboxCandidates,
  snapshotFilename,
} from "./snapshot.js"

let cachedEmailHash

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

async function readEmailHash($, home) {
  if (cachedEmailHash !== undefined) return cachedEmailHash || null
  try {
    if (!home) return null
    const text = await $.fs.read(`${home.replace(/\/$/, "")}/.claude.json`)
    const email = extractEmail(text)
    cachedEmailHash = email ? await hashEmail(email) : ""
  } catch {
    return null
  }
  return cachedEmailHash || null
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

/// Capability detection: a missing usage() throws and is treated as "write nothing".
export async function recordMeasure($) {
  try {
    const usage = await $.session.usage()
    const home = await readHome($)
    const emailHash = await readEmailHash($, home)
    const snapshot = buildSnapshot({ now: new Date().toISOString(), usage, emailHash })
    if (!snapshot) return false
    return await writeSnapshot($, snapshot, snapshotFilename(emailHash))
  } catch {
    return false
  }
}

export function register(on) {
  on("session.measure", async ($, event, next) => {
    await recordMeasure($).catch((error) => errorText(error))
    return next(event)
  })
}
