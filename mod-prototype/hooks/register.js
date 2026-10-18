import {
  buildSnapshot,
  errorText,
  findStableIdentity,
  hashIdentity,
} from "./probe.js"

let measureEvents = 0
let latestSnapshot = null
let capturing = false

const COMMAND = "balancebar-mod-spike"

async function tryCall(label, operation) {
  if (typeof operation !== "function") {
    return { ok: false, label, error: "API unavailable" }
  }
  try {
    return { ok: true, value: await operation() }
  } catch (error) {
    return { ok: false, label, error: errorText(error) }
  }
}

async function observe(label, operation) {
  try {
    return await operation()
  } catch (error) {
    return { status: "blocked", label, error: errorText(error) }
  }
}

async function readEnv($, name) {
  const operations = {
    HOME: () => $.env.get("HOME"),
    BALANCEBAR_MOD_INBOX: () => $.env.get("BALANCEBAR_MOD_INBOX"),
    BALANCEBAR_MOD_LOCAL_URL: () => $.env.get("BALANCEBAR_MOD_LOCAL_URL"),
    BALANCEBAR_MOD_FORCE_FAILURE: () => $.env.get("BALANCEBAR_MOD_FORCE_FAILURE"),
  }
  const result = await tryCall(`env.get:${name}`, operations[name])
  return result.ok && typeof result.value === "string" ? result.value : undefined
}

async function envFlag($, name) {
  const value = await readEnv($, name)
  return ["1", "true", "yes"].includes((value ?? "").toLowerCase())
}

async function readSessionDetails($) {
  const details = {}
  const errors = []
  const methods = {
    version: () => $.session.version(),
    model: () => $.session.model(),
    id: () => $.session.id(),
    surfaces: () => $.session.surfaces(),
  }
  for (const name of Object.keys(methods)) {
    const result = await tryCall(`session.${name}`, methods[name])
    if (result.ok) details[name] = result.value
    else if (result.error !== "API unavailable") errors.push(result)
  }
  return { details, errors }
}

async function readAccountProbe($) {
  const home = await readEnv($, "HOME")
  if (!home) return { status: "blocked", error: "HOME is unavailable" }

  const accountPath = `${home.replace(/\/$/, "")}/.claude.json`
  const file = await tryCall("fs.read:claude-config", () => $.fs.read(accountPath))
  if (!file.ok) return { status: "blocked", error: file.error }

  let parsed
  try {
    parsed = JSON.parse(file.value)
  } catch (error) {
    return { status: "blocked", error: `invalid JSON: ${errorText(error)}` }
  }

  const candidate = findStableIdentity(parsed)
  if (!candidate) return { status: "unavailable", error: "no supported identity field found" }

  try {
    return {
      status: "hashed",
      source: candidate.source,
      identityHash: await hashIdentity(candidate.value),
    }
  } catch (error) {
    return { status: "blocked", error: `hash failed: ${errorText(error)}` }
  }
}

function isLoopback(url) {
  try {
    const parsed = new URL(url)
    return parsed.protocol === "http:" && ["localhost", "127.0.0.1", "::1"].includes(parsed.hostname)
  } catch {
    return false
  }
}

async function writeSnapshot($, snapshot) {
  const configuredInbox = await readEnv($, "BALANCEBAR_MOD_INBOX")
  const home = await readEnv($, "HOME")
  const attempts = []
  const directories = configuredInbox
    ? [{ label: "configured", path: configuredInbox }]
    : home
      ? [
          {
            label: "application-support-inbox",
            path: `${home.replace(/\/$/, "")}/Library/Application Support/BalanceBar/inbox`,
          },
          {
            label: "claude-fallback",
            path: `${home.replace(/\/$/, "")}/.claude/balancebar-inbox`,
          },
        ]
      : []

  const payload = `${JSON.stringify(snapshot, null, 2)}\n`
  const filename = `balancebar-mod-spike-${Date.now()}.json`
  for (const directory of directories) {
    const exists = await tryCall(`fs.exists:${directory.label}`, () => $.fs.exists(directory.path))
    if (!exists.ok) {
      attempts.push({ target: directory.label, path: directory.path, status: "blocked", error: exists.error })
      continue
    }
    if (!exists.value) {
      attempts.push({ target: directory.label, path: directory.path, status: "missing" })
      continue
    }

    const outputPath = `${directory.path.replace(/\/$/, "")}/${filename}`
    const write = await tryCall(`fs.write:${directory.label}`, () => $.fs.write(outputPath, payload))
    if (write.ok) {
      return { status: "written", target: directory.label, path: outputPath, attempts }
    }
    attempts.push({ target: directory.label, path: outputPath, status: "blocked", error: write.error })
  }

  const endpoint = await readEnv($, "BALANCEBAR_MOD_LOCAL_URL")
  if (endpoint) {
    if (!isLoopback(endpoint)) {
      return { status: "blocked", attempts, endpoint: "rejected: non-loopback URL" }
    }
    const response = await tryCall("http.fetch:local", () => $.http.fetch(endpoint, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: payload,
    }))
    if (response.ok && response.value?.ok) {
      return { status: "sent-to-local-endpoint", statusCode: response.value.status, attempts }
    }
    attempts.push({
      target: "local-endpoint",
      endpoint,
      status: "blocked",
      error: response.ok ? `HTTP ${response.value?.status ?? "unknown"}` : response.error,
    })
  }

  return {
    status: "blocked",
    attempts,
    reason: directories.length === 0 ? "HOME and BALANCEBAR_MOD_INBOX are unavailable" : "no writable destination",
  }
}

async function capture($, { event, includeAccount = false, write = false, allowForcedFailure = false } = {}) {
  if (capturing) return latestSnapshot
  capturing = true
  try {
    if (allowForcedFailure && await envFlag($, "BALANCEBAR_MOD_FORCE_FAILURE")) {
      throw new Error("forced probe failure for isolation test")
    }

    const usage = await tryCall("session.usage", () => $.session.usage())
    const session = await readSessionDetails($)
    const account = includeAccount ? await readAccountProbe($) : { status: "not-requested" }
    const snapshot = buildSnapshot({
      now: new Date().toISOString(),
      usage: usage.ok ? usage.value : {},
      session: session.details,
      account: account.identityHash ? account : null,
      event,
      measureEvents,
    })

    const apiErrors = [usage, ...session.errors].filter((result) => !result.ok)
    if (apiErrors.length > 0) {
      snapshot.mod_observation.api_errors = apiErrors.map(({ label, error }) => ({ label, error }))
    }
    if (includeAccount) {
      snapshot.mod_observation.account_probe = {
        status: account.status,
        source: account.source,
        error: account.error,
      }
    }
    if (write) snapshot.mod_observation.write = await writeSnapshot($, snapshot)

    latestSnapshot = snapshot
    return snapshot
  } finally {
    capturing = false
  }
}

function resultText(result) {
  const observation = result?.mod_observation
  if (!observation) {
    return `balancebar-mod-spike: ${result?.status ?? "blocked"}${result?.error ? ` (${result.error})` : ""}`
  }
  const write = observation.write ?? { status: "not-requested" }
  const account = observation.account_probe?.status ?? (result.account ? "hashed" : "not-requested")
  const lines = [
    `balancebar-mod-spike: event=${observation.event ?? "unknown"}`,
    `rateLimits=${observation.rate_limits_available ? "available" : "unavailable"} · measureEvents=${observation.measure_events ?? 0}`,
    `account=${account} · write=${write.status}`,
  ]
  if (write.path) lines.push(`path=${write.path}`)
  return lines.join("\n")
}

export function register(on) {
  on("session.start", async ($, event, next) => {
    await observe("session.start", async () => {
      await tryCall("command.register", () => $.command.register({
        name: COMMAND,
        description: "Capture a redacted BalanceBar Mod feasibility snapshot",
        argumentHint: "[probe]",
      }))
      latestSnapshot = await capture($, { event: "session.start", allowForcedFailure: true })
    })
    return next(event)
  })

  on("session.measure", async ($, event, next) => {
    measureEvents += 1
    await observe("session.measure", async () => {
      latestSnapshot = await capture($, { event: "session.measure", allowForcedFailure: true })
    })
    return next(event)
  })

  on("command.run", { command: COMMAND }, async ($) => {
    const result = await observe("command.run", () => capture($, {
      event: "command.run",
      includeAccount: true,
      write: true,
      allowForcedFailure: true,
    }))
    return { text: resultText(result) }
  })
}
