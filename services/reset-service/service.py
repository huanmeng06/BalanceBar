"""Shared observation deadlines. No account quota or reset-completion inference."""
from __future__ import annotations

from datetime import datetime, timedelta, timezone
import hashlib
import json
import re
from zoneinfo import ZoneInfo

UTC = timezone.utc
PACIFIC = ZoneInfo("America/Los_Angeles")
SOURCE = "https://codex-reset.com/"
MAX_TEXT = 6000
POLICY = "pacific-local-v1"


class Invalid(ValueError):
    """Unusable external data; messages are fixed diagnostic codes."""


def instant(value):
    if not isinstance(value, str) or not re.fullmatch(
        r"\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d(?:\.\d{1,6})?(?:Z|[+-]\d\d:\d\d)", value
    ):
        raise Invalid("invalid_timestamp")
    try:
        return datetime.fromisoformat(value.replace("Z", "+00:00")).astimezone(UTC)
    except ValueError:
        raise Invalid("invalid_timestamp") from None


def iso(value):
    return value.astimezone(UTC).isoformat(timespec="seconds").replace("+00:00", "Z")


def encode(value):
    return json.dumps(value, ensure_ascii=False, sort_keys=True, allow_nan=False).encode("utf-8")


def digest(value):
    return hashlib.sha256(encode(value)).hexdigest()


def text(value, maximum=MAX_TEXT):
    if not isinstance(value, str) or not value.strip() or len(value) > maximum:
        raise Invalid("invalid_text")
    return value


def post_id(value):
    if not isinstance(value, str) or not re.fullmatch(r"[0-9]{1,24}", value):
        raise Invalid("invalid_post_id")
    return value


def normalize(raw, posts, official=False):
    pid = post_id(raw.get("tweet_id", raw.get("id")))
    item = posts.get(pid, raw)
    published = instant(item.get("at"))
    body = text(item.get("text", raw.get("summary")))
    if official and raw.get("at") is not None and instant(raw["at"]) != published:
        raise Invalid("source_timestamp_conflict")
    # Never follow supplied links, and accept only the known author's post URL.
    url = item.get("url", raw.get("url"))
    if url != f"https://x.com/thsottiaux/status/{pid}":
        raise Invalid("invalid_source_url")
    parent_id = item.get("in_reply_to_tweet_id")
    reply = item.get("is_reply", raw.get("is_reply")) is True or parent_id is not None
    parent = posts.get(parent_id) if isinstance(parent_id, str) else None
    context = None
    if parent:
        context = {"post_id": post_id(parent.get("id")), "text": text(parent.get("text")),
                   "published_at": iso(instant(parent.get("at")))}
        if instant(context["published_at"]) > published:
            raise Invalid("parent_after_child")
    complete = (not reply and item.get("is_reply") is False) or (
        context is not None and parent.get("is_reply") is False and not parent.get("in_reply_to_tweet_id"))
    signal = {"post_id": pid, "published_at": iso(published), "source_url": url,
              "source_provider": "codex-reset.com", "text": body,
              "context_complete": complete, "parent": context,
              "conversation_id": item.get("conversation_id") if isinstance(item.get("conversation_id"), str) and re.fullmatch(r"[0-9]{1,24}", item["conversation_id"]) else None}
    # Source timestamps/context and policy belong to the interpretation identity too.
    signal["version"] = digest({"signal": signal, "policy": POLICY})
    return {"signal": signal, "official": official, "window": raw.get("window"),
            "source_conflict": official and raw.get("summary") is not None and raw["summary"] != body}


TIME_HINT = re.compile(r"\b(midnight|tomorrow|today|within|before|by|landing|lands|am|pm)\b", re.I)
RESET_HINT = re.compile(r"\b(reset|resets|resetting)\b", re.I)
UNSAFE = re.compile(
    r"\b(not|never|maybe|might|possibly|perhaps|if|joke|joking|quoted|quoting|"
    r"hypothetically|ignore|instructions|system|prompt|pretend|EOD)\b|\bno\s+reset\b|[\"“”]", re.I
)


def candidates(forecast, feed, state, now):
    if not isinstance(forecast, dict) or not isinstance(feed, dict):
        raise Invalid("upstream_shape")
    for value in (forecast.get("updated_at"), feed.get("fetched_at")):
        age = now - instant(value)
        if age < timedelta(minutes=-5) or age > timedelta(minutes=30):
            raise Invalid("upstream_stale")
    if feed.get("stale") is not False:
        raise Invalid("feed_stale_or_unknown")
    rows = feed.get("tweets", feed.get("events"))
    if not isinstance(rows, list) or len(rows) > 1000:
        raise Invalid("upstream_shape")
    posts = {}
    for row in rows:
        if isinstance(row, dict) and isinstance(row.get("id"), str):
            if row["id"] in posts and posts[row["id"]] != row:
                raise Invalid("duplicate_post_conflict")
            posts[row["id"]] = row
    if "official_signal" not in forecast:
        raise Invalid("missing_official_signal")
    raw = forecast["official_signal"]
    if raw is not None and not isinstance(raw, dict):
        raise Invalid("upstream_shape")
    if raw is not None and not raw:
        raise Invalid("empty_official_signal")
    if raw is not None:
        headline = feed.get("signal")
        if isinstance(headline, dict) and headline.get("tweet_id") == raw.get("tweet_id"):
            raw = dict(headline, **raw)
    official = normalize(raw, posts, True) if raw else None
    current = official["signal"]["post_id"] if official else None
    previous = state.get("official_id")
    if previous and previous != current:
        state["retired"] = sorted(set(state.get("retired", []) + [previous]))
    state["official_id"] = current
    reset = instant(forecast["last_reset_at"]) if forecast.get("last_reset_at") else None
    cutoff = max(now - timedelta(hours=24), reset or now - timedelta(hours=24))
    result = []
    if official:
        at = instant(official["signal"]["published_at"])
        if at > now:
            raise Invalid("future_post")
        if at >= cutoff:
            result.append(official)
            cutoff = max(cutoff, at)
    for row in posts.values():
        if row.get("id") == current or row.get("id") in state.get("retired", []):
            continue
        try:
            candidate = normalize(row, posts)
            sig = candidate["signal"]
            at = instant(sig["published_at"])
            if not cutoff <= at <= now or row.get("active") is False:
                continue
            context = sig["text"] + "\n" + (sig["parent"] or {}).get("text", "")
            if RESET_HINT.search(context) and TIME_HINT.search(sig["text"]) and not UNSAFE.search(context):
                result.append(candidate)
        except Invalid:
            # Optional, malformed feed rows do not invalidate a valid official signal.
            continue
    return sorted(result, key=lambda c: (not c["official"], c["signal"]["published_at"], c["signal"]["post_id"]))


def local_instant(day, hour, minute):
    naive = datetime.combine(day, datetime.min.time()).replace(hour=hour, minute=minute)
    possibilities = set()
    for fold in (0, 1):
        aware = naive.replace(tzinfo=PACIFIC, fold=fold)
        utc = aware.astimezone(UTC)
        if utc.astimezone(PACIFIC).replace(tzinfo=None) == naive:
            possibilities.add(utc)
    if len(possibilities) != 1:
        raise Invalid("dst_ambiguous_or_nonexistent")
    return possibilities.pop()


def checked_deadline(signal, analysis):
    """AI selects evidence; code verifies supported lexical anchors and does all arithmetic."""
    if not isinstance(analysis, dict) or analysis.get("kind") != "explicit_deadline":
        raise Invalid("not_explicit")
    for field in ("reset_related", "asserted", "unambiguous"):
        if analysis.get(field) is not True:
            raise Invalid("unsafe_semantics")
    evidence = text(analysis.get("evidence"), 1000)
    text(analysis.get("basis"), 1000)
    body = signal["text"]
    context = body + "\n" + (signal["parent"] or {}).get("text", "")
    if evidence not in body or UNSAFE.search(context) or not signal["context_complete"]:
        raise Invalid("unsupported_evidence_or_context")
    published = instant(signal["published_at"])
    local = published.astimezone(PACIFIC)
    # Reject an evidence slice that hides a second time/date elsewhere in the post.
    duration = list(re.finditer(r"\bwithin\s+(?:the\s+)?next\s+(\d{1,2})\s+hours?\b", body, re.I))
    clocks = list(re.finditer(r"\b(1[0-2]|[1-9])(?::([0-5]\d))?\s*(am|pm)\b", body, re.I))
    midnights = list(re.finditer(r"\bmidnight\b", body, re.I))
    if len(duration) + len(clocks) + len(midnights) != 1:
        raise Invalid("conflicting_or_unsupported_times")
    if duration:
        match = duration[0]
        hours = int(match[1])
        if match[0].lower() not in evidence.lower() or not 1 <= hours <= 24 or re.search(r"\b(tomorrow|today|PST|PDT|PT)\b", body, re.I):
            raise Invalid("unsupported_duration")
        deadline = published + timedelta(hours=hours)
    else:
        zone = list(re.finditer(r"\b(PST|PDT|PT)\b", body, re.I))
        if len(zone) != 1 or zone[0][0].lower() not in evidence.lower():
            raise Invalid("missing_or_conflicting_timezone")
        tomorrow = len(re.findall(r"\btomorrow\b", body, re.I))
        today = len(re.findall(r"\btoday\b", body, re.I))
        dates = re.findall(r"\b\d{4}-\d\d-\d\d\b", body)
        if tomorrow + today + len(dates) > 1:
            raise Invalid("conflicting_dates")
        if dates:
            try:
                day = datetime.strptime(dates[0], "%Y-%m-%d").date()
            except ValueError:
                raise Invalid("invalid_date") from None
        else:
            day = local.date() + timedelta(days=tomorrow)
        if midnights:
            if midnights[0][0].lower() not in evidence.lower():
                raise Invalid("missing_time_evidence")
            deadline = local_instant(day + timedelta(days=1), 0, 0)
        else:
            match = clocks[0]
            if match[0].lower() not in evidence.lower() or not (tomorrow or today or dates):
                raise Invalid("missing_date_or_time_evidence")
            hour = int(match[1]) % 12 + (12 if match[3].lower() == "pm" else 0)
            deadline = local_instant(day, hour, int(match[2] or 0))
    if not published < deadline <= published + timedelta(hours=72):
        raise Invalid("invalid_deadline_order")
    return deadline


def uncertain(code, method=None, evidence=None, kind="uncertain"):
    return {"kind": kind, "deadline_at": None, "evidence": evidence, "method": method,
            "diagnostic": code, "timezone_policy": POLICY}


def interpret(candidate, analyze, now):
    signal = candidate["signal"]
    window = candidate["window"]
    if window is not None and candidate.get("source_conflict"):
        return uncertain("source_text_conflict", "upstream_structured")
    if window is not None:
        if not isinstance(window, dict):
            return uncertain("invalid_structured_window", "upstream_structured")
        values = [window[k] for k in ("target_at", "end_at") if window.get(k) is not None]
        if values:
            try:
                deadlines = {instant(value) for value in values}
                deadline = next(iter(deadlines))
                published = instant(signal["published_at"])
                if len(deadlines) != 1 or not published < deadline <= published + timedelta(hours=72):
                    raise Invalid("structured_conflict_or_order")
                if deadline <= now:
                    return uncertain("expired", "upstream_structured")
                return {"kind": "explicit_deadline", "deadline_at": iso(deadline),
                        "evidence": "official_signal.window", "method": "upstream_structured",
                        "diagnostic": "structured", "timezone_policy": POLICY}
            except Invalid as exc:
                return uncertain(str(exc), "upstream_structured")
    context = signal["text"] + "\n" + (signal["parent"] or {}).get("text", "")
    if not signal["context_complete"] or UNSAFE.search(context):
        return uncertain("unsafe_text_or_missing_context")
    analysis = analyze(signal)
    if not isinstance(analysis, dict):
        return uncertain("invalid_analysis", "ai_interpreted")
    if analysis.get("kind") != "explicit_deadline":
        kind = analysis.get("kind")
        if kind not in ("approximate_window", "not_reset_related", "uncertain"):
            kind = "uncertain"
        return uncertain("non_explicit", "ai_interpreted", kind=kind)
    try:
        deadline = checked_deadline(signal, analysis)
        if deadline <= now:
            return uncertain("expired", "ai_interpreted")
        return {"kind": "explicit_deadline", "deadline_at": iso(deadline),
                "evidence": analysis["evidence"], "method": "ai_interpreted",
                "diagnostic": "validated", "timezone_policy": POLICY}
    except (Invalid, ValueError) as exc:
        return uncertain(str(exc) if isinstance(exc, Invalid) else "invalid_analysis", "ai_interpreted")


def document(now, status, signal=None, observation=None, diagnostics=None, verified=True):
    observation = observation or uncertain("unavailable" if status == "error" else "no_current_signal")
    until = now + timedelta(minutes=30) if verified else now
    if observation["deadline_at"]:
        until = min(until, instant(observation["deadline_at"]))
    return {"schema_version": 1, "generated_at": iso(now),
            "last_verified_at": iso(now) if verified else None, "valid_until": iso(until),
            "status": status, "source": SOURCE, "signal": signal,
            "observation": observation, "diagnostics": diagnostics or []}


def evaluate(forecast, feed, state, analyze, now):
    found = candidates(forecast, feed, state, now)
    if not found:
        return document(now, "none")
    if len(found) > 10:
        return document(now, "uncertain", diagnostics=["too_many_candidates"])
    results = [(c, interpret(c, analyze, now)) for c in found]
    meaningful = [(c, o) for c, o in results if o["kind"] != "not_reset_related" and o["diagnostic"] != "expired"]
    if not meaningful:
        return document(now, "none", diagnostics=["expired_or_unrelated"])
    # Two posts with the same time are still distinct identities; do not silently reconcile.
    if len(meaningful) > 1:
        return document(now, "uncertain", diagnostics=["multiple_current_posts"])
    candidate, observation = meaningful[0]
    return document(now, "deadline" if observation["deadline_at"] else "uncertain",
                    candidate["signal"], observation)


def validate_public(doc):
    if len(encode(doc)) > 65536:
        raise Invalid("public_size_limit")
    if doc["schema_version"] != 1 or doc["status"] not in ("deadline", "uncertain", "none", "error"):
        raise Invalid("public_contract")
    generated = instant(doc["generated_at"])
    expires = instant(doc["valid_until"])
    deadline = doc["observation"]["deadline_at"]
    if expires > generated + timedelta(minutes=30):
        raise Invalid("public_expiry")
    if doc["status"] == "deadline":
        if not doc["signal"] or not deadline or not generated < expires <= instant(deadline):
            raise Invalid("public_deadline")
    elif deadline is not None:
        raise Invalid("public_non_deadline")
    return doc
