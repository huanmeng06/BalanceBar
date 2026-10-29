import { expect, test } from "claude-code/testing"
import { buildSnapshot, extractEmail, extractOrganization, hashEmail, inboxCandidates, snapshotFilename } from "../hooks/snapshot.js"
import { bindSession, createSessionBinding, recordMeasure, writeSnapshot } from "../hooks/register.js"

const NOW = "2026-10-19T00:00:00.000Z"
const usage = {
  rateLimits: [
    { kind: "five_hour", percentUsed: 34, resetsAt: "2026-10-19T04:00:00.000Z" },
    { kind: "seven_day", percentUsed: 61.5, resetsAt: "2026-10-21T00:00:00.000Z" },
    { kind: "extra_usage", percentUsed: 5, resetsAt: 12345 },
  ],
}

function fakeContext(overrides: Record<string, unknown> = {}) {
  const written: Record<string, string> = {}
  const $ = {
    env: { get: async (name: string) => ({ HOME: "/home/x", BALANCEBAR_MOD_INBOX: "/inbox" } as Record<string, string>)[name] },
    session: { usage: async () => usage },
    fs: {
      exists: async () => true,
      read: async () => JSON.stringify({ oauthAccount: { emailAddress: "A@Example.com", accessToken: "secret" } }),
      write: async (path: string, data: string) => { written[path] = data },
    },
    ...overrides,
  }
  return { $, written }
}

test("builds a Schema v1 superset with raw kinds and ISO-only resets", () => {
  const s = buildSnapshot({ now: NOW, usage, emailHash: "sha256:abc" })!
  expect(s.source).toBe("balancebar-mod")
  expect(s.five_hour).toEqual({ used_percentage: 34, resets_at: "2026-10-19T04:00:00.000Z" })
  expect(s.seven_day.used_percentage).toBe(61.5)
  expect(s.account).toEqual({ email_hash: "sha256:abc" })
  expect(s.windows.length).toBe(3)
  expect(s.windows[2]).toEqual({ kind: "extra_usage", used_percentage: 5 })
})

test("returns null without usable rateLimits", () => {
  expect(buildSnapshot({ now: NOW, usage: {}, emailHash: null })).toBe(null)
  expect(buildSnapshot({ now: NOW, usage: { rateLimits: [] }, emailHash: null })).toBe(null)
  expect(buildSnapshot({ now: NOW, usage: { rateLimits: [{ kind: "five_hour" }] }, emailHash: null })).toBe(null)
})

test("only the lowercased email is hashed, never exposed", async () => {
  const email = extractEmail(JSON.stringify({ oauthAccount: { emailAddress: "A@Example.com", accessToken: "t" } }))
  expect(await hashEmail(email!)).toBe(await hashEmail("a@example.com"))
  expect(extractEmail("not json")).toBe(null)
  expect(snapshotFilename("sha256:0123456789abcdef0123")).toBe("balancebar-mod-0123456789abcdef.json")
})

test("inbox candidates honour override then default and fallback", () => {
  expect(inboxCandidates({ home: "/h", configured: "/c" })).toEqual(["/c"])
  expect(inboxCandidates({ home: "/h/" })).toEqual(["/h/Library/Application Support/BalanceBar/inbox", "/h/.claude/balancebar-inbox"])
  expect(inboxCandidates({})).toEqual([])
})

test("writes a snapshot without plaintext email or token", async () => {
  const { $, written } = fakeContext()
  expect(await recordMeasure($)).toBe(true)
  const body = Object.values(written)[0]
  expect(body.includes("example.com")).toBe(false)
  expect(body.includes("secret")).toBe(false)
  expect(JSON.parse(body).account.email_hash.startsWith("sha256:")).toBe(true)
})

test("writes nothing when usage() or rateLimits is unavailable", async () => {
  const none = fakeContext({ session: {} })
  expect(await recordMeasure(none.$)).toBe(false)
  const noLimits = fakeContext({ session: { usage: async () => ({}) } })
  expect(await recordMeasure(noLimits.$)).toBe(false)
  expect(Object.keys(none.written).length + Object.keys(noLimits.written).length).toBe(0)
})

test("write failure returns false instead of throwing", async () => {
  const { $ } = fakeContext({
    fs: { exists: async () => true, read: async () => "{}", write: async () => { throw new Error("EROFS") } },
  })
  expect(await writeSnapshot($, { a: 1 }, "x.json")).toBe(false)
})

test("missing inbox directory is skipped, not created", async () => {
  const { $, written } = fakeContext({
    fs: { exists: async () => false, read: async () => "{}", write: async (p: string, d: string) => { written[p] = d } },
  })
  expect(await writeSnapshot($, { a: 1 }, "x.json")).toBe(false)
})

test("account switch is picked up on the next measure", async () => {
  let email = "a@example.com"
  const { $, written } = fakeContext()
  ;($ as any).fs.read = async () => JSON.stringify({ oauthAccount: { emailAddress: email } })
  await recordMeasure($)
  email = "b@example.com"
  await recordMeasure($)
  const names = Object.keys(written)
  expect(names.length).toBe(2)
  expect(names[0] === names[1]).toBe(false)
  expect(JSON.parse(written[names[1]]).account.email_hash).toBe(await hashEmail("b@example.com"))
})

test("organization hash is written and selects a per-organization file", async () => {
  const config = (org: string) => JSON.stringify({ oauthAccount: { emailAddress: "a@example.com", organizationUuid: org } })
  const run = async (org: string) => {
    const { $, written } = fakeContext({
      fs: { exists: async () => true, read: async () => config(org), write: async (path: string, data: string) => { written[path] = data } },
    })
    expect(await recordMeasure($)).toBe(true)
    const [path, body] = Object.entries(written)[0]
    return { path, account: JSON.parse(body).account, body }
  }
  const one = await run("ORG-1")
  const two = await run("org-2")
  expect(one.account.organization_hash).toBe(await hashEmail("org-1"))
  expect(one.account.email_hash).toBe(two.account.email_hash)
  expect(one.path).not.toBe(two.path)
  expect(one.body.toLowerCase().includes("org-1")).toBe(false)
  expect(one.path.endsWith(".json")).toBe(true)
})

test("without an organization the legacy email-only file name and account shape are kept", async () => {
  expect(extractOrganization(JSON.stringify({ oauthAccount: { organizationUuid: "  " } }))).toBe(null)
  expect(extractOrganization("not json")).toBe(null)
  expect(snapshotFilename("sha256:0123456789abcdef0123", null)).toBe("balancebar-mod-0123456789abcdef.json")
  expect(snapshotFilename("sha256:0123456789abcdef0123", "sha256:fedcba9876543210ffff"))
    .toBe("balancebar-mod-0123456789abcdef-fedcba9876543210.json")
  const s = buildSnapshot({ now: NOW, usage, emailHash: "sha256:abc", organizationHash: null })!
  expect(s.account).toEqual({ email_hash: "sha256:abc" })
})

function sessionContext(options: { startedAgo?: number; config: () => string; usageFails?: boolean }) {
  const written: Record<string, string> = {}
  const now = 1_000_000_000
  const $ = {
    env: { get: async (name: string) => ({ HOME: "/home/x", BALANCEBAR_MOD_INBOX: "/inbox" } as Record<string, string>)[name] },
    clock: { now: async () => now },
    session: {
      usage: async () => {
        if (options.usageFails) throw new Error("not ready")
        return { ...usage, startedAt: now - (options.startedAgo ?? 1_000) }
      },
    },
    fs: { exists: async () => true, read: async () => options.config(), write: async (path: string, data: string) => { written[path] = data } },
  }
  return { $, written }
}

const configFor = (org: string, email = "a@example.com") =>
  JSON.stringify({ oauthAccount: { emailAddress: email, organizationUuid: org } })

test("a session whose account or organization changed under it writes nothing", async () => {
  let config = configFor("org-a")
  const { $, written } = sessionContext({ config: () => config })
  const sessionA = createSessionBinding()
  await bindSession($, sessionA)
  expect(await recordMeasure($, sessionA)).toBe(true)

  // The global config now names organization B, but session A keeps measuring organization A's usage.
  for (const key of Object.keys(written)) delete written[key]
  config = configFor("org-b")
  expect(await recordMeasure($, sessionA)).toBe(false)
  expect(Object.keys(written).length).toBe(0)

  // A session started after the switch is bound to B and writes B's own file.
  const sessionB = createSessionBinding()
  await bindSession($, sessionB)
  expect(await recordMeasure($, sessionB)).toBe(true)
  expect(JSON.parse(Object.values(written)[0]).account.organization_hash).toBe(await hashEmail("org-b"))

  // A different email under the same session is refused the same way.
  config = configFor("org-b", "c@example.com")
  expect(await recordMeasure($, sessionB)).toBe(false)
})

test("a module reloaded into a running session cannot be proven and writes nothing", async () => {
  // The session began 10 minutes ago under organization A; the config was switched to B since.
  const { $, written } = sessionContext({ startedAgo: 600_000, config: () => configFor("org-b") })
  const reloaded = createSessionBinding()
  await bindSession($, reloaded)
  expect(reloaded.status).toBe("untrusted")
  expect(await recordMeasure($, reloaded)).toBe(false)
  expect(Object.keys(written).length).toBe(0)
})

test("an unreadable account at start leaves the session untrusted even after the config appears", async () => {
  let config = "{}"
  const { $, written } = sessionContext({ config: () => config })
  const binding = createSessionBinding()
  await bindSession($, binding)
  config = configFor("org-b")
  expect(await recordMeasure($, binding)).toBe(false)
  expect(Object.keys(written).length).toBe(0)
})

test("measuring before any session start, or with usage unavailable at start, writes nothing", async () => {
  const unbound = sessionContext({ config: () => configFor("org-a") })
  expect(await recordMeasure(unbound.$, createSessionBinding())).toBe(false)
  const failing = sessionContext({ usageFails: true, config: () => configFor("org-a") })
  const binding = createSessionBinding()
  await bindSession(failing.$, binding)
  expect(binding.status).toBe("untrusted")
  expect(Object.keys(unbound.written).length + Object.keys(failing.written).length).toBe(0)
})
