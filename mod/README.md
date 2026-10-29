# BalanceBar Mod

Claude Code Mod that writes a BalanceBar quota snapshot (Schema v1 superset) after
each `session.measure` event, covering interactive, `claude -p` and Agent SDK
sessions. Requires Claude Code v2.1.287 or newer; older terminals do not load
Mods and simply produce no snapshots (see `docs/research/mod-spike.md`).

## Behaviour

- Subscribes only to `session.measure`; every failure is swallowed so the session is never affected.
- Capability detection: if `$.session.usage()` is missing, throws, or has no usable `rateLimits`, nothing is written.
- Output: `updated_at`, `five_hour`/`seven_day` (when present), `source: "balancebar-mod"`,
  `account.email_hash` and `account.organization_hash` (`sha256:` of the lowercased account email / `oauthAccount.organizationUuid`; plaintext email, organization and tokens are never written; the organization hash is omitted when Claude Code exposes no organization),
  and `windows[]` keeping Claude's raw `kind`. `resets_at` is written only when Claude supplies an ISO string;
  other formats are omitted rather than guessed.
- Destination: first existing directory of `~/Library/Application Support/BalanceBar/inbox/`,
  then `~/.claude/balancebar-inbox/`. Directories are never created. `BALANCEBAR_MOD_INBOX` overrides (testing).
- One file per account and organization, `balancebar-mod-<email16>-<org16>.json` (`balancebar-mod-<email16>.json` without an organization), overwritten with the latest observation.

## Validate and test

```sh
claude plugin validate ./mod --strict
claude plugin test ./mod
```

## Install

```sh
claude plugin marketplace add ./mod --scope local --json
claude plugin install balancebar-mod@balancebar-mods --scope local --json
```
