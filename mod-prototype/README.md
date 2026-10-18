# BalanceBar Mod spike

This is an opt-in Claude Code Mod probe for Issue #512. It records the shape of
`$.session.usage()` and the `session.measure` event, then exposes an explicit
command that can test a redacted account hash and one of three delivery paths:

1. `~/Library/Application Support/BalanceBar/inbox/`;
2. a `~/.claude/balancebar-inbox/` fallback; or
3. an explicitly configured loopback HTTP endpoint.

The Mod does not read `~/.claude.json`, write a file, or make a network request
until `/balancebar-mod-spike` is run. It never writes the raw account file or a
raw account identifier. The fallback directory is not created automatically;
this keeps the probe's result meaningful and makes the required permission
boundary visible.

## Files

- `.claude-plugin/plugin.json`: plugin manifest.
- `.claude-plugin/marketplace.json`: a local marketplace wrapper for install testing.
- `hooks/register.js`: `session.start`, `session.measure`, and the explicit probe command.
- `hooks/probe.js`: pure snapshot mapping and account-candidate helpers.
- `tests/probe.test.ts`: no-network mapping tests for `claude plugin test`.

## Validate and test

Run from the repository root:

```sh
claude plugin validate ./mod-prototype --strict
claude plugin test ./mod-prototype
```

These commands validate local files and run the Mod test kit. They do not start
a Claude session, sign in, read a user account file, or make a network request.

## Load without installing

```sh
claude --plugin-dir ./mod-prototype
```

After a session starts, run `/plugin` and confirm `balancebar-mod-spike` is
listed. After editing an already-open installed session, run `/reload-plugins`.
The command `/balancebar-mod-spike` prints a redacted summary and attempts the
explicit probes. Its JSON output is written only when one of the destinations
is already available.

For a safe temporary inbox, create one outside the repository and pass it to
the Claude process:

```sh
BALANCEBAR_MOD_INBOX=/tmp/balancebar-mod-inbox claude --plugin-dir ./mod-prototype
```

The directory must exist before the command runs. For the loopback alternative,
set `BALANCEBAR_MOD_LOCAL_URL=http://127.0.0.1:<port>/balancebar/inbox` and run a
local test server you control. Non-loopback URLs are rejected by the probe.

`BALANCEBAR_MOD_FORCE_FAILURE=1` deliberately fails the probe inside the
protected observation path. Use it only for the session-isolation check.

For a headless turn, opt in to one snapshot write per `session.measure` event:

```sh
MEASURE_INBOX="$(mktemp -d /tmp/balancebar-mod-measure.XXXXXX)"
BALANCEBAR_MOD_INBOX="$MEASURE_INBOX" \
BALANCEBAR_MOD_RECORD_MEASURE=1 \
claude -p "请只回复：headless measure test" --plugin-dir ./mod-prototype
find "$MEASURE_INBOX" -type f -name 'balancebar-mod-spike-*.json' -print
```

An output file whose `mod_observation.event` is `session.measure` is the
observable evidence that the event fired. The flag is opt-in and is off by
default so ordinary sessions do not write on every measurement.

## Install-command probe

The exact local-marketplace commands are:

```sh
claude plugin marketplace add ./mod-prototype --scope local --json
claude plugin install balancebar-mod-spike@balancebar-mods --scope local --json
```

The first command should report `marketplace-add` with `outcome: "ok"`; the
second should report `install` with `outcome: "ok"`. An already-installed
plugin is an exit-0, already-in-goal-state result. Run these only in a disposable
Claude Code test profile because they edit Claude Code's local plugin settings.

## Safety boundary

The probe is evidence collection, not a production Mod. It intentionally keeps
the account file and delivery destinations out of automated tests. A successful
manifest/test run is not evidence that a particular Claude Code surface emits
`session.measure`; follow `docs/research/mod-spike.md` for the empirical matrix.
