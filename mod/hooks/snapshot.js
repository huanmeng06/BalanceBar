// Pure mapping helpers: Claude Code usage -> BalanceBar Schema v1 superset.
const INBOX_SUBPATH = "Library/Application Support/BalanceBar/inbox"
const FALLBACK_SUBPATH = ".claude/balancebar-inbox"

export function inboxCandidates({ home, configured }) {
  if (configured) return [configured]
  if (!home) return []
  const root = home.replace(/\/$/, "")
  return [`${root}/${INBOX_SUBPATH}`, `${root}/${FALLBACK_SUBPATH}`]
}

export function errorText(error) {
  return error instanceof Error && error.message ? error.message : String(error ?? "unknown error")
}

function isoOrNull(value) {
  if (typeof value !== "string") return null
  return Number.isNaN(Date.parse(value)) ? null : value
}

function normalizeWindow(rateLimit) {
  if (typeof rateLimit?.kind !== "string" || !rateLimit.kind) return null
  const percent = rateLimit.percentUsed
  if (typeof percent !== "number" || !Number.isFinite(percent)) return null
  const window = { kind: rateLimit.kind, used_percentage: percent }
  const resetsAt = isoOrNull(rateLimit.resetsAt)
  if (resetsAt) window.resets_at = resetsAt
  return window
}

function topLevel(window) {
  const { kind, ...rest } = window
  return rest
}

/// Returns null (write nothing) when usage has no usable rateLimits.
export function buildSnapshot({ now, usage, emailHash, organizationHash }) {
  if (!Array.isArray(usage?.rateLimits)) return null
  const windows = usage.rateLimits.map(normalizeWindow).filter(Boolean)
  if (windows.length === 0) return null

  const snapshot = { updated_at: now }
  const fiveHour = windows.find((w) => w.kind === "five_hour")
  const sevenDay = windows.find((w) => w.kind === "seven_day")
  if (fiveHour) snapshot.five_hour = topLevel(fiveHour)
  if (sevenDay) snapshot.seven_day = topLevel(sevenDay)
  snapshot.source = "balancebar-mod"
  if (emailHash) {
    snapshot.account = { email_hash: emailHash }
    if (organizationHash) snapshot.account.organization_hash = organizationHash
  }
  snapshot.windows = windows
  return snapshot
}

export async function hashEmail(value) {
  const normalized = String(value).trim().toLowerCase()
  const digest = await globalThis.crypto.subtle.digest("SHA-256", new TextEncoder().encode(normalized))
  const hex = Array.from(new Uint8Array(digest), (b) => b.toString(16).padStart(2, "0")).join("")
  return `sha256:${hex}`
}

/// Extracts only the account email from ~/.claude.json text; never returns other fields.
export function extractEmail(configText) {
  try {
    const email = JSON.parse(configText)?.oauthAccount?.emailAddress
    return typeof email === "string" && email.trim() ? email : null
  } catch {
    return null
  }
}

/// Extracts only the organization UUID from ~/.claude.json text; it is hashed before use.
export function extractOrganization(configText) {
  try {
    const organization = JSON.parse(configText)?.oauthAccount?.organizationUuid
    return typeof organization === "string" && organization.trim() ? organization : null
  } catch {
    return null
  }
}

function hashPrefix(hash) {
  return hash.replace("sha256:", "").slice(0, 16)
}

/// One file per email + organization; without an organization the legacy email-only name is kept.
export function snapshotFilename(emailHash, organizationHash) {
  const suffix = emailHash ? hashPrefix(emailHash) : "unknown"
  const organization = emailHash && organizationHash ? `-${hashPrefix(organizationHash)}` : ""
  return `balancebar-mod-${suffix}${organization}.json`
}
