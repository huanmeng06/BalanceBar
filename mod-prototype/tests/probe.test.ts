import { expect, test } from "claude-code/testing"
import { buildSnapshot, canonicalWindowKind, findStableIdentity } from "../hooks/probe.js"

test("maps known windows while retaining the raw rate-limit kinds", () => {
  const snapshot = buildSnapshot({
    now: "2026-10-18T00:00:00.000Z",
    usage: {
      context: { percent: 12 },
      rateLimits: [
        { kind: "five_hour", percentUsed: 34, resetsAt: "2026-10-18T04:00:00Z" },
        { kind: "seven_day", percentUsed: 61.5, resetsAt: "2026-10-21T00:00:00Z" },
      ],
    },
    session: { version: "2.1.291", surfaces: ["terminal"] },
    account: null,
    event: "test",
    measureEvents: 1,
  })

  expect(snapshot.five_hour.used_percentage).toBe(34)
  expect(snapshot.seven_day.resets_at).toBe("2026-10-21T00:00:00Z")
  expect(snapshot.windows[0].kind).toBe("five_hour")
  expect(snapshot.mod_observation.raw_rate_limits[1].percentUsed).toBe(61.5)
  expect(snapshot.mod_observation.context_percent).toBe(12)
})

test("does not invent top-level fields for an unknown window kind", () => {
  const snapshot = buildSnapshot({
    now: "2026-10-18T00:00:00.000Z",
    usage: { rateLimits: [{ kind: "unknown-plan", percentUsed: 9, resetsAt: 1 }] },
    session: {},
    account: null,
    event: "test",
  })

  expect(canonicalWindowKind("unknown-plan")).toBe(null)
  expect(snapshot.five_hour).toBe(undefined)
  expect(snapshot.seven_day).toBe(undefined)
  expect(snapshot.windows[0].resets_at).toBe(1)
})

test("only supported identity fields are selected for hashing", () => {
  expect(findStableIdentity({ oauthAccount: { accountUuid: "account-123" } }).path).toBe("oauthAccount.accountUuid")
  expect(findStableIdentity({ unrelated: { id: "not-an-account" } })).toBe(null)
})
