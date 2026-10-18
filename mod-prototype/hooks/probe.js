const IDENTITY_CANDIDATES = [
  ["oauthAccount.accountUuid", "account-id"],
  ["oauthAccount.accountUUID", "account-id"],
  ["oauthAccount.uuid", "account-id"],
  ["oauthAccount.id", "account-id"],
  ["accountUuid", "account-id"],
  ["account.uuid", "account-id"],
  ["account.id", "account-id"],
  ["user.uuid", "account-id"],
  ["user.id", "account-id"],
  ["oauthAccount.emailAddress", "email"],
  ["email", "email"],
]

export function scalar(value) {
  if (value === null || value === undefined) return null
  if (typeof value === "string" || typeof value === "boolean") return value
  if (typeof value === "number") return Number.isFinite(value) ? value : null
  return String(value)
}

export function errorText(error) {
  if (error instanceof Error && error.message) return error.message
  return scalar(error) ?? "unknown error"
}

export function canonicalWindowKind(kind) {
  const compact = String(kind ?? "").toLowerCase().replace(/[^a-z0-9]/g, "")
  if (["5h", "5hour", "fivehour"].includes(compact)) return "five_hour"
  if (["7d", "7day", "sevenday"].includes(compact)) return "seven_day"
  return null
}

export function normalizeRateLimit(rateLimit) {
  const kind = scalar(rateLimit?.kind) ?? "unknown"
  const percentUsed = scalar(rateLimit?.percentUsed)
  const resetsAt = scalar(rateLimit?.resetsAt)
  return {
    kind,
    used_percentage: typeof percentUsed === "number" ? percentUsed : null,
    resets_at: resetsAt,
  }
}

function rawRateLimit(rateLimit) {
  return {
    kind: scalar(rateLimit?.kind),
    percentUsed: scalar(rateLimit?.percentUsed),
    resetsAt: scalar(rateLimit?.resetsAt),
  }
}

function pathValue(root, path) {
  return path.split(".").reduce((value, key) => {
    if (!value || typeof value !== "object") return undefined
    return value[key]
  }, root)
}

export function findStableIdentity(root) {
  for (const [path, source] of IDENTITY_CANDIDATES) {
    const value = pathValue(root, path)
    if (typeof value === "string" && value.trim()) {
      return { path, source, value: value.trim() }
    }
  }
  return null
}

export async function hashIdentity(value) {
  const bytes = new TextEncoder().encode(value)
  const digest = await globalThis.crypto.subtle.digest("SHA-256", bytes)
  const hex = Array.from(new Uint8Array(digest), (byte) => byte.toString(16).padStart(2, "0")).join("")
  return `sha256:${hex}`
}

export function buildSnapshot({ now, usage, session, account, event, measureEvents = 0 }) {
  const rateLimits = Array.isArray(usage?.rateLimits) ? usage.rateLimits : []
  const windows = rateLimits.map(normalizeRateLimit)
  const snapshot = { updated_at: now }

  const fiveHour = windows.find((window) => canonicalWindowKind(window.kind) === "five_hour")
  const sevenDay = windows.find((window) => canonicalWindowKind(window.kind) === "seven_day")
  if (fiveHour) snapshot.five_hour = { ...fiveHour, kind: undefined }
  if (sevenDay) snapshot.seven_day = { ...sevenDay, kind: undefined }

  if (snapshot.five_hour) delete snapshot.five_hour.kind
  if (snapshot.seven_day) delete snapshot.seven_day.kind

  snapshot.source = "balancebar-mod"
  if (account?.identityHash) {
    snapshot.account = {
      identity_hash: account.identityHash,
      identity_source: account.source,
    }
  }
  snapshot.windows = windows
  snapshot.mod_observation = {
    event: scalar(event),
    measure_events: measureEvents,
    rate_limits_available: Array.isArray(usage?.rateLimits),
    raw_rate_limits: rateLimits.map(rawRateLimit),
    context_percent: scalar(usage?.context?.percent),
    session_version: scalar(session?.version),
    surfaces: Array.isArray(session?.surfaces)
      ? session.surfaces.map(scalar).filter((value) => value !== null)
      : scalar(session?.surfaces),
  }
  return snapshot
}
