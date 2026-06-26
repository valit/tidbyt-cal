#!/usr/bin/env python3
"""
calendar_check.py — Tidbyt smart render scheduler.

Runs every 5 minutes via GitHub Actions (triggered by cron-job.org posting
{"event_type":"tidbyt-check"} to the repo dispatches API).

Computes display-change moments from the iCal feed and manages one-time
cron-job.org jobs so renders fire exactly at those moments rather than on a
fixed 5-minute cycle.

Ledger: ledger.json (committed to the repo) tracks which cron-job.org jobs
we've created, so we never need to call GET /jobs. The workflow commits any
changes to ledger.json back to the repo after this script runs.
cron-job.org API calls only happen when the calendar actually changes.

Configuration: config.json at the repo root defines calendars and devices.
Each calendar has an id and a url_secret (name of the GitHub Secret holding
its iCal URL). Each device lists which calendar ids it subscribes to.

Required environment variables:
  CRONJOB_API_KEY — cron-job.org API key
  DISPATCH_TOKEN  — GitHub PAT; used for direct dispatch triggers and embedded
                    in cron-job.org one-time job request headers
  GITHUB_REPO     — e.g. "valit/tidbyt-cal" (set via ${{ github.repository }})
  + one env var per calendar url_secret (e.g. ICAL_URL, ICAL_URL_PERSONAL)

One-time setup after deploying this script:
  Update cron-job.org job 7866088 so its request body is
  {"event_type":"tidbyt-check"} instead of {"event_type":"tidbyt-push"}.
  This redirects the 5-minute heartbeat to calendar_check.yml.
  render.yml becomes the sole handler for tidbyt-push events.
"""

import datetime
import hashlib
import json
import os
import sys
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen

from icalendar import Calendar
import recurring_ical_events

# ── Display-change timing constants (must mirror my_calendar.star) ─────────────

PREP_TIME          = int(os.environ.get("PREP_TIME") or 900)
ALERT_WINDOW       = int(os.environ.get("ALERT_WINDOW") or 300)
PERSISTENCE_TIME   = int(os.environ.get("PERSISTENCE_TIME") or 600)
EXTENDED_THRESHOLD = int(os.environ.get("EXTENDED_THRESHOLD") or 14400)
LOOKAHEAD          = 2 * 60 * 60  # schedule moments up to this far ahead
NEAR_TERM_SECS     = 120       # moments ≤ this close → trigger render directly now

CRONJOB_BASE     = "https://api.cron-job.org"
GITHUB_API_BASE  = "https://api.github.com"
JOB_TITLE_PREFIX = "tidbyt-moment-"
LEDGER_FILE      = "ledger.json"


# ── HTTP helper ────────────────────────────────────────────────────────────────

def http(method, url, headers, body=None):
    """Perform an HTTP request. Returns (status_code, parsed_body_dict)."""
    data = json.dumps(body).encode() if body is not None else None
    req = Request(url, data=data, method=method, headers=headers)
    try:
        resp = urlopen(req, timeout=20)
        raw = resp.read()
        return resp.status, json.loads(raw) if raw else {}
    except HTTPError as exc:
        raw = exc.read()
        try:
            parsed = json.loads(raw)
        except Exception:
            parsed = {}
        return exc.code, parsed
    except URLError as exc:
        raise RuntimeError(f"Network error {method} {url}: {exc}") from exc


# ── cron-job.org API ───────────────────────────────────────────────────────────

def _cj_headers(api_key):
    return {"Authorization": f"Bearer {api_key}", "Content-Type": "application/json"}


def moment_title(moment):
    """Stable string key for a UTC moment, used as the cron-job.org job title."""
    return JOB_TITLE_PREFIX + moment.strftime("%Y%m%dT%H%M")


def create_job(api_key, dispatch_token, repo, moment, devices):
    """Create a one-time cron-job.org job that fires at *moment* (UTC datetime,
    already floored to the minute). Returns the integer jobId, or None on failure.

    The job POSTs a tidbyt-push dispatch to GitHub with a client_payload
    listing the device names that need to render at this moment.
    """
    dispatch_body = {
        "event_type": "tidbyt-push",
        "client_payload": {"devices": sorted(devices)},
    }
    payload = {
        "job": {
            "url": f"{GITHUB_API_BASE}/repos/{repo}/dispatches",
            "title": moment_title(moment),
            "enabled": True,
            "saveResponses": False,
            "expiresAt": int((moment + datetime.timedelta(hours=1)).timestamp()),
            "schedule": {
                "timezone": "UTC",
                "hours":   [moment.hour],
                "minutes": [moment.minute],
                "mdays":   [moment.day],
                "months":  [moment.month],
                "wdays":   [-1],   # -1 = any day of week (not constraining)
            },
            "requestMethod": 1,  # POST
            "extendedData": {
                "headers": {
                    "Authorization": f"Bearer {dispatch_token}",
                    "Accept":        "application/vnd.github.v3+json",
                    "Content-Type":  "application/json",
                },
                "body": json.dumps(dispatch_body),
            },
        }
    }
    status, data = http("PUT", f"{CRONJOB_BASE}/jobs", _cj_headers(api_key), payload)
    if status in (200, 201) and "jobId" in data:
        print(f"  + created job {data['jobId']} → {moment_title(moment)} for {sorted(devices)}")
        return data["jobId"]
    print(f"  ! create_job unexpected response {status}: {data}", file=sys.stderr)
    return None


def delete_job(api_key, job_id):
    """Delete a cron-job.org job by ID. 404 (already gone) is silently ignored."""
    status, _ = http("DELETE", f"{CRONJOB_BASE}/jobs/{job_id}", _cj_headers(api_key))
    if status == 404:
        print(f"  - deleted job {job_id} (already gone)")
    elif status in (200, 204):
        print(f"  - deleted job {job_id}")
    else:
        print(f"  ! delete_job {job_id} unexpected status {status}", file=sys.stderr)


# ── Ledger (ledger.json committed to repo) ─────────────────────────────────────

def read_ledger():
    """Read the scheduled-jobs ledger from ledger.json.
    Returns a dict with keys: ical_hash (str), jobs (list of {job_id, moment}).
    """
    try:
        with open(LEDGER_FILE) as f:
            return json.load(f)
    except (FileNotFoundError, json.JSONDecodeError):
        return {"ical_hash": "", "jobs": []}


def write_ledger(ledger):
    """Write the ledger to ledger.json. The workflow commits it back to the repo."""
    with open(LEDGER_FILE, "w") as f:
        json.dump(ledger, f, separators=(",", ":"))
        f.write("\n")


# ── GitHub dispatch ────────────────────────────────────────────────────────────

def trigger_render(dispatch_token, repo, devices):
    """Fire a repository_dispatch event to trigger render.yml immediately."""
    body = {
        "event_type": "tidbyt-push",
        "client_payload": {"devices": sorted(devices)},
    }
    status, data = http(
        "POST",
        f"{GITHUB_API_BASE}/repos/{repo}/dispatches",
        {
            "Authorization": f"Bearer {dispatch_token}",
            "Accept": "application/vnd.github.v3+json",
            "Content-Type": "application/json",
        },
        body,
    )
    if status not in (200, 204):
        raise RuntimeError(f"trigger_render: unexpected status {status}: {data}")
    print(f"  → triggered immediate render for {sorted(devices)} via repository_dispatch")


# ── iCal fetching and parsing ──────────────────────────────────────────────────

def fetch_ical(url):
    resp = urlopen(url, timeout=20)
    return resp.read().decode("utf-8", errors="replace")


def to_utc(dt):
    """Convert a datetime to UTC-aware. Returns None for date-only values (all-day events)."""
    if not isinstance(dt, datetime.datetime):
        return None  # datetime.date → all-day event, skip
    if dt.tzinfo is None:
        return dt.replace(tzinfo=datetime.timezone.utc)
    return dt.astimezone(datetime.timezone.utc)


def parse_events(ical_text, now):
    """Return a list of {uid, start, end} dicts for all timed events that could
    produce change moments within the lookahead window.

    Search window:
      - Back: EXTENDED_THRESHOLD + buffer, to catch long in-progress events
              whose end times fall within the lookahead window.
      - Forward: LOOKAHEAD + PREP_TIME + buffer, to catch events whose
                 prep_time moment (15 min before start) falls within lookahead.
    """
    cal = Calendar.from_ical(ical_text)
    search_start = now - datetime.timedelta(seconds=EXTENDED_THRESHOLD + 120)
    search_end   = now + datetime.timedelta(seconds=LOOKAHEAD + PREP_TIME + 120)

    events = []
    for ev in recurring_ical_events.of(cal).between(search_start, search_end):
        raw_start = ev.get("DTSTART")
        raw_end   = ev.get("DTEND")
        if raw_start is None or raw_end is None:
            continue
        start = to_utc(raw_start.dt)
        end   = to_utc(raw_end.dt)
        if start is None or end is None:
            continue  # all-day event
        uid = str(ev.get("UID", "")) or ""
        events.append({"uid": uid, "start": start, "end": end})
    return events


def fetch_calendar_events(cal_config, now):
    """Fetch and parse one calendar. Tags each event with calendar_id.
    Returns [] on missing secret or fetch/parse failure (logs but doesn't crash).
    """
    cal_id = cal_config["id"]
    url_secret = cal_config["url_secret"]
    url = os.environ.get(url_secret)
    if not url:
        print(f"  ! Calendar '{cal_id}': env var {url_secret} not set — skipping", file=sys.stderr)
        return []
    try:
        events = parse_events(fetch_ical(url), now)
        for e in events:
            e["calendar_id"] = cal_id
        print(f"  Calendar '{cal_id}': {len(events)} event(s) in window")
        return events
    except Exception as exc:
        print(f"  ! Calendar '{cal_id}': fetch/parse failed — {exc}", file=sys.stderr)
        return []


def dedupe_events(events):
    """Merge event lists, dropping duplicates by (uid, start_unix).
    Falls back to (summary, start_unix) for events with no UID.
    First occurrence wins.
    """
    seen = set()
    result = []
    for e in events:
        uid = e.get("uid", "")
        start_unix = int(e["start"].timestamp())
        key = (uid, start_unix) if uid else (e.get("summary", ""), start_unix)
        if key not in seen:
            seen.add(key)
            result.append(e)
    return result


def load_config():
    """Load config.json from the current directory."""
    with open("config.json") as f:
        return json.load(f)


# ── Change-moment logic ────────────────────────────────────────────────────────

def is_extended(event):
    return (event["end"] - event["start"]).total_seconds() > EXTENDED_THRESHOLD


def compute_moments(events, now):
    """Return a set of UTC datetimes (floored to the minute) representing all
    display-change moments that fall within (now, now + LOOKAHEAD].

    Moment types (matching select_event logic in my_calendar.star):
      prep_time   — event.start − PREP_TIME    (switch to showing upcoming event)
      alert       — event.start − ALERT_WINDOW (alert flash begins)
      start       — event.start                (event is now current)
      end         — event.end                  (event is over; show next)
      persistence — event.start + PERSISTENCE_TIME  (extended event defers)
    """
    cutoff = now + datetime.timedelta(seconds=LOOKAHEAD)
    moments = set()

    for e in events:
        candidates = [
            e["start"] - datetime.timedelta(seconds=PREP_TIME),
            e["start"] - datetime.timedelta(seconds=ALERT_WINDOW),
            e["start"],
            e["end"],
        ]
        if is_extended(e):
            candidates.append(e["start"] + datetime.timedelta(seconds=PERSISTENCE_TIME))

        for t in candidates:
            # Floor to minute: cron-job.org is minute-granular. Flooring is
            # conservative (render fires slightly early), which is correct —
            # the Starlark app recomputes from real clock time at render time.
            t_min = t.replace(second=0, microsecond=0)
            if now < t_min <= cutoff:
                moments.add(t_min)

    return moments


# ── Main ───────────────────────────────────────────────────────────────────────

def main():
    config         = load_config()
    cronjob_key    = os.environ["CRONJOB_API_KEY"]
    dispatch_token = os.environ["DISPATCH_TOKEN"]
    gh_repo        = os.environ.get("GITHUB_REPO", "valit/tidbyt-cal")
    all_device_names = sorted(d["name"] for d in config["devices"])

    # Floor now to the minute for consistent moment comparisons.
    now = datetime.datetime.now(datetime.timezone.utc).replace(second=0, microsecond=0)
    print(f"[calendar_check] {now.isoformat()}  repo={gh_repo}")

    # 1. Fetch all calendars, tag events with calendar_id, merge and dedupe.
    #    Missing secrets and fetch failures are logged but don't crash.
    raw_events = []
    for cal in config["calendars"]:
        raw_events.extend(fetch_calendar_events(cal, now))
    all_events = dedupe_events(raw_events)

    # 2. Fingerprint over the full merged event set (calendar_id included so a
    #    per-device change also invalidates the cache).
    ical_hash = hashlib.sha256(
        json.dumps(sorted(
            (e.get("calendar_id", ""), e["start"].isoformat(), e["end"].isoformat())
            for e in all_events
        )).encode()
    ).hexdigest()[:16]

    # 3. Per-device moment computation, grouped by timestamp across devices.
    #    moment_devices: {moment → set of device names that care about it}
    moment_devices: dict = {}
    for device in config["devices"]:
        device_events = [e for e in all_events if e.get("calendar_id") in device["calendars"]]
        for m in compute_moments(device_events, now):
            moment_devices.setdefault(m, set()).add(device["name"])

    # 4. Read the current ledger.
    ledger      = read_ledger()
    ledger_jobs = ledger.get("jobs", [])

    # 5. Near-term moments (≤ NEAR_TERM_SECS away): trigger render directly.
    all_desired = set(moment_devices.keys())
    near   = {m for m in all_desired if (m - now).total_seconds() <= NEAR_TERM_SECS}
    future = all_desired - near

    if near:
        near_devices: set = set()
        for m in near:
            near_devices.update(moment_devices[m])
        print(f"  Near-term: {[m.isoformat() for m in sorted(near)]} → rendering now for {sorted(near_devices)}")
        trigger_render(dispatch_token, gh_repo, near_devices)

    # 6. Build ledger index.
    ledger_by_moment = {
        datetime.datetime.fromisoformat(e["moment"]): e
        for e in ledger_jobs
    }

    # 7. Diff: what needs to be deleted and/or created.
    #    A job must be deleted if its moment is past, no longer needed, or
    #    if the set of devices it targets has changed.
    to_delete = []
    for m, entry in ledger_by_moment.items():
        if m < now or m not in future:
            to_delete.append(entry)
        elif set(entry.get("devices", [])) != moment_devices[m]:
            to_delete.append(entry)  # devices changed → recreate

    to_create: dict = {}
    for m in future:
        if m not in ledger_by_moment:
            to_create[m] = moment_devices[m]
        elif set(ledger_by_moment[m].get("devices", [])) != moment_devices[m]:
            to_create[m] = moment_devices[m]  # devices changed → recreate

    # 8. Early exit: nothing to do and calendar hasn't changed.
    #    Exception: when the ledger is empty and no moments exist the display may
    #    be stale, so fall through to the safety-net render at the end.
    if not near and not to_create and not to_delete and ledger.get("ical_hash") == ical_hash:
        if ledger_jobs or all_desired:
            print("  No changes — skipping cron-job.org API calls.")
            return
        # Idle with empty ledger — fall through to safety-net render.

    print(f"  ical_hash now={ical_hash} prev={ledger.get('ical_hash', 'none')}")
    print(f"  Future moments ({len(future)}): {[m.isoformat() for m in sorted(future)]}")
    print(f"  To create: {len(to_create)}, to delete: {len(to_delete)}")

    # 9. Delete stale / outdated jobs from cron-job.org.
    for entry in to_delete:
        delete_job(cronjob_key, entry["job_id"])

    # 10. Create new / updated jobs and build the surviving ledger.
    to_delete_ids = {e["job_id"] for e in to_delete}
    surviving = [e for e in ledger_jobs if e["job_id"] not in to_delete_ids]
    for moment in sorted(to_create):
        devices = sorted(to_create[moment])
        job_id = create_job(cronjob_key, dispatch_token, gh_repo, moment, devices)
        if job_id is not None:
            surviving.append({"job_id": job_id, "moment": moment.isoformat(), "devices": devices})

    # 11. Write the updated ledger to disk; the workflow commits it back to the repo.
    new_ledger = {"ical_hash": ical_hash, "jobs": surviving}
    write_ledger(new_ledger)
    print(f"  Ledger written: {len(surviving)} job(s) now scheduled.")

    # 12. Safety net: if no moments were found and the ledger is now empty, the
    #     display may be showing stale content (e.g. an event that just ended with
    #     no upcoming events in the lookahead window). Render all devices.
    if not surviving and not all_desired:
        print("  Safety-net: empty ledger and no upcoming moments — triggering render.")
        trigger_render(dispatch_token, gh_repo, all_device_names)


if __name__ == "__main__":
    try:
        main()
    except Exception as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        sys.exit(1)
