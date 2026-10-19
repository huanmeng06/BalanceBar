import { expect, test } from "claude-code/testing"
import { buildSnapshot, extractEmail, hashEmail, inboxCandidates, snapshotFilename } from "../hooks/snapshot.js"
import { recordMeasure, writeSnapshot } from "../hooks/register.js"

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
