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

Required environment variables:
  ICAL_URL        — private Google Calendar iCal feed URL
  CRONJOB_API_KEY — cron-job.org API key
  DISPATCH_TOKEN  — GitHub PAT; used for direct dispatch triggers and embedded
                    in cron-job.org one-time job request headers
  GITHUB_REPO     — e.g. "valit/tidbyt-cal" (set via ${{ github.repository }})

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

PREP_TIME          = 15 * 60   # show upcoming event this many seconds early
ALERT_WINDOW       = 5 * 60    # alert flash begins this many seconds before start
PERSISTENCE_TIME   = 10 * 60   # extended events hold for this long before deferring
EXTENDED_THRESHOLD = 4 * 3600  # events longer than this are "extended" (flights, etc.)
LOOKAHEAD          = 60 * 60   # schedule moments up to this far ahead
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


def create_job(api_key, dispatch_token, repo, moment):
    """Create a one-time cron-job.org job that fires at *moment* (UTC datetime,
    already floored to the minute). Returns the integer jobId, or None on failure.

    The job POSTs {"event_type":"tidbyt-push"} to the GitHub dispatches API,
    which triggers render.yml. The schedule fires exactly once (then again a
    year later, but the next heartbeat will delete it as stale before that).
    """
    payload = {
        "job": {
            "url": f"{GITHUB_API_BASE}/repos/{repo}/dispatches",
            "title": moment_title(moment),
            "enabled": True,
            "saveResponses": False,
            "schedule": {
                "timezone": "UTC",
                "hours":   [moment.hour],
                "minutes": [moment.minute],
                "mdays":   [moment.day],
                "months":  [moment.month],
                "wdays":   [-1],   # -1 = any day of week (not constraining)
            },
            "requestMethod": 1,  # POST
            "requestBody": json.dumps({"event_type": "tidbyt-push"}),
            "requestHeaders": [
                {"name": "Authorization", "value": f"Bearer {dispatch_token}"},
                {"name": "Accept",        "value": "application/vnd.github.v3+json"},
                {"name": "Content-Type",  "value": "application/json"},
            ],
        }
    }
    status, data = http("PUT", f"{CRONJOB_BASE}/jobs", _cj_headers(api_key), payload)
    if status in (200, 201) and "jobId" in data:
        print(f"  + created job {data['jobId']} → {moment_title(moment)}")
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

def trigger_render(dispatch_token, repo):
    """Fire a repository_dispatch event to trigger render.yml immediately."""
    status, data = http(
        "POST",
        f"{GITHUB_API_BASE}/repos/{repo}/dispatches",
        {
            "Authorization": f"Bearer {dispatch_token}",
            "Accept": "application/vnd.github.v3+json",
            "Content-Type": "application/json",
        },
        {"event_type": "tidbyt-push"},
    )
    if status not in (200, 204):
        raise RuntimeError(f"trigger_render: unexpected status {status}: {data}")
    print("  → triggered immediate render via repository_dispatch")


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
    """Return a list of {start, end} dicts for all timed events that could
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
        events.append({"start": start, "end": end})
    return events


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
    ical_url       = os.environ["ICAL_URL"]
    cronjob_key    = os.environ["CRONJOB_API_KEY"]
    dispatch_token = os.environ["DISPATCH_TOKEN"]
    gh_repo        = os.environ.get("GITHUB_REPO", "valit/tidbyt-cal")

    # Floor now to the minute for consistent moment comparisons.
    now = datetime.datetime.now(datetime.timezone.utc).replace(second=0, microsecond=0)
    print(f"[calendar_check] {now.isoformat()}  repo={gh_repo}")

    # 1. Fetch iCal and compute a short hash for change detection.
    ical_text = fetch_ical(ical_url)
    ical_hash = hashlib.sha256(ical_text.encode()).hexdigest()[:16]

    # 2. Read ledger from ledger.json (already on disk from git checkout).
    ledger      = read_ledger()
    ledger_jobs = ledger.get("jobs", [])  # list of {job_id: int, moment: ISO str}

    # 3. Compute the desired set of future moments from the current calendar.
    events      = parse_events(ical_text, now)
    all_moments = compute_moments(events, now)

    # 4. Near-term moments (≤ NEAR_TERM_SECS away): trigger render directly
    #    instead of scheduling, because cron-job.org propagation may be too slow.
    near   = {m for m in all_moments if (m - now).total_seconds() <= NEAR_TERM_SECS}
    future = all_moments - near

    if near:
        print(f"  Near-term: {[m.isoformat() for m in sorted(near)]} → rendering now")
        trigger_render(dispatch_token, gh_repo)

    # 5. Build ledger index and compute the diff.
    ledger_by_moment = {
        datetime.datetime.fromisoformat(e["moment"]): e
        for e in ledger_jobs
    }
    ledger_moments = set(ledger_by_moment.keys())
    to_create      = future - ledger_moments
    to_delete      = [ledger_by_moment[m] for m in ledger_moments if m not in future]

    # 6. Early exit: nothing to do and calendar hasn't changed.
    if not near and not to_create and not to_delete and ledger.get("ical_hash") == ical_hash:
        print("  No changes — skipping cron-job.org API calls.")
        return

    print(f"  ical_hash now={ical_hash} prev={ledger.get('ical_hash', 'none')}")
    print(f"  Future moments ({len(future)}): {[m.isoformat() for m in sorted(future)]}")
    print(f"  To create: {len(to_create)}, to delete: {len(to_delete)}")

    # 7. Delete stale jobs from cron-job.org.
    for entry in to_delete:
        delete_job(cronjob_key, entry["job_id"])

    # 8. Create new jobs on cron-job.org and build the surviving ledger.
    surviving = [ledger_by_moment[m] for m in ledger_moments if m in future]
    for moment in sorted(to_create):
        job_id = create_job(cronjob_key, dispatch_token, gh_repo, moment)
        if job_id is not None:
            surviving.append({"job_id": job_id, "moment": moment.isoformat()})

    # 9. Write the updated ledger to disk; the workflow commits it back to the repo.
    new_ledger = {"ical_hash": ical_hash, "jobs": surviving}
    write_ledger(new_ledger)
    print(f"  Ledger written: {len(surviving)} job(s) now scheduled.")


if __name__ == "__main__":
    try:
        main()
    except Exception as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        sys.exit(1)
