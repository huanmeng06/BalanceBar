#!/usr/bin/env python3
"""Production entrypoint; state initialization requires explicit --initialize-state."""
import argparse
from datetime import datetime, timedelta, timezone
import os
from pathlib import Path

from runtime import Analyzer, GitHubState, HTTP, Retryable, atomic_json
from service import Invalid, document, evaluate, instant, iso, validate_public


def run(store, http, key, now, clock=None):
    try:
        state = store.load()
        if state.get("upstream_retry_after") and instant(state["upstream_retry_after"]) > now:
            raise Invalid("upstream_cooldown")
        try:
            forecast = http.json("https://codex-reset.com/api/forecast", upstream=True)
            feed = http.json("https://codex-reset.com/api/feed", upstream=True)
        except Retryable as exc:
            state["upstream_retry_after"] = iso(now + timedelta(seconds=exc.delay))
            store.save(state)
            raise
        analyzer = Analyzer(state, store.save, http, key, now, clock=clock)
        result = evaluate(forecast, feed, state, analyzer, now)
        store.save(state)
        result["diagnostics"] += sorted(set(analyzer.events))
        return validate_public(result)
    except (Invalid, KeyError, TypeError, ValueError, OSError):
        # No exception bodies, credentials, response text or old deadline in public errors/logs.
        return validate_public(document(now, "error", diagnostics=["fetch_analysis_or_state_failure"], verified=False))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", required=True)
    parser.add_argument("--initialize-state", action="store_true")
    args = parser.parse_args()
    repo = os.environ.get("GITHUB_REPOSITORY", "huanmeng06/BalanceBar")
    store = GitHubState(repo)
    if args.initialize_state:
        store.initialize()
    result = run(store, HTTP(), os.environ.get("RESET_SERVICE_DEEPSEEK_API_KEY"), datetime.now(timezone.utc), clock=lambda: datetime.now(timezone.utc))
    atomic_json(Path(args.output) / "reset-service/v1/latest.json", result)
    print(f"reset-service status={result['status']} diagnostic={result['observation']['diagnostic']} events={','.join(result['diagnostics'])}")


if __name__ == "__main__":
    main()
