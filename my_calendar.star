"""
my_calendar.star — Tidbyt/Pixlet app

Shows the next relevant event from a private Google Calendar iCal feed,
with a pixel-precise three-row layout on the 64x32 display.

LAYOUT (64x32, origin top-left)
  ROW 1  calendar2.png icon (11x11) at x=2,y=2  +  date in magenta
  ROW 2  event title (white, as written), marquee-scrolled full width
  ROW 3  time in yellow ("At H:MM am/pm" or "All day"), near the bottom

  All text uses the standard Tidbyt font "tb-8".
  Vertical offsets are derived from the spec's baseline rules:
    - Row 3 baseline 2px above the bottom edge        -> text box top y=24
    - Row 2 baseline 2px above top of Row 3 caps      -> text box top y=16
    - Icon bottom 3px above top of Row 2 caps         -> icon top y=2
    - Date baseline 2px above icon bottom edge          -> text box top y=5

  Note: Pixlet runs in a sandbox with no filesystem access, so the
  11x11 "calendar2.png" in this folder is embedded below as base64 and
  decoded at render time for render.Image.
"""

load("render.star", "render")
load("http.star", "http")
load("time.star", "time")
load("encoding/base64.star", "base64")

ICAL_URL = "***REMOVED-ICAL-URL***"

LOCATION = "America/Los_Angeles"

# Colors
PINK = "#FF69B4"
WHITE = "#FFFFFF"
YELLOW = "#FFD700"
BLACK = "#000000"

FONT = "tb-8"

MONTHS = ["JAN", "FEB", "MAR", "APR", "MAY", "JUN", "JUL", "AUG", "SEP", "OCT", "NOV", "DEC"]

TTL_SECONDS = 300  # cache the iCal fetch for 5 minutes
SWITCH_LEAD = 5 * 60  # seconds: switch to a contiguous next event 5 min early

# 11x11 calendar2.png (same image as the file in this folder), base64-encoded.
CALENDAR_PNG = base64.decode("iVBORw0KGgoAAAANSUhEUgAAAAsAAAALCAYAAACprHcmAAAAUklEQVQYldWQMQ7AIAwDbYQY+o78/28MnY0SmoUFGGspg62LI4WSMEUB4mcyewC8mTNgUvCdBQ1lLjkV9kgFF6rz1EE5eddcfgijm1X/9W66WRsDuCd2VGR7ZQAAAABJRU5ErkJggg==")

def main():
    tz = LOCATION
    now = time.now().in_location(tz)

    events = fetch_events(tz)
    event = select_event(events, now, tz)

    if event == None:
        return render_no_events()

    return render_event(event)

# ---------------------------------------------------------------------------
# Rendering
# ---------------------------------------------------------------------------

def render_event(event):
    date_str = format_date(event["start"])
    title = event["summary"]  # preserved exactly as in the calendar

    if event["all_day"]:
        time_str = "All day"
    else:
        time_str = format_time(event["start"])

    return render.Root(
        child = render.Stack(
            children = [
                # Background fixes the canvas at 64x32 so the Padding offsets
                # below are measured from the true top-left corner.
                render.Box(width = 64, height = 32, color = BLACK),

                # ROW 1 — calendar icon at (2, 2)
                render.Padding(
                    pad = (2, 2, 0, 0),
                    child = render.Image(src = CALENDAR_PNG, width = 11, height = 11),
                ),
                # ROW 1 — date text, 2px right of the icon
                render.Padding(
                    pad = (15, 5, 0, 0),
                    child = render.Text(content = date_str, color = PINK, font = FONT),
                ),

                # ROW 2 — title, full-width marquee (no horizontal padding)
                render.Padding(
                    pad = (0, 16, 0, 0),
                    child = render.Marquee(
                        width = 64,
                        child = render.Text(content = title, color = WHITE, font = FONT),
                    ),
                ),

                # ROW 3 — time, 2px from the left
                render.Padding(
                    pad = (2, 24, 0, 0),
                    child = render.Text(content = time_str, color = YELLOW, font = FONT),
                ),
            ],
        ),
    )

def render_no_events():
    # Same 3-row layout as the main display: icon + today's date on top, then
    # two static yellow lines (no marquee).
    date_str = format_date(time.now().in_location(LOCATION))

    return render.Root(
        child = render.Stack(
            children = [
                render.Box(width = 64, height = 32, color = BLACK),

                # ROW 1 — calendar icon at (2, 2) + today's date
                render.Padding(
                    pad = (2, 2, 0, 0),
                    child = render.Image(src = CALENDAR_PNG, width = 11, height = 11),
                ),
                render.Padding(
                    pad = (15, 5, 0, 0),
                    child = render.Text(content = date_str, color = PINK, font = FONT),
                ),

                # ROW 2 — static line, 2px from the left
                render.Padding(
                    pad = (2, 16, 0, 0),
                    child = render.Text(content = "ALL DONE", color = YELLOW, font = FONT),
                ),

                # ROW 3 — static line, 2px from the left
                render.Padding(
                    pad = (2, 24, 0, 0),
                    child = render.Text(content = "FOR TODAY :)", color = YELLOW, font = FONT),
                ),
            ],
        ),
    )

# ---------------------------------------------------------------------------
# Event selection
# ---------------------------------------------------------------------------

def select_event(events, now, tz):
    timed = [e for e in events if not e["all_day"]]

    # 1. Timed event currently in progress (earliest end if several overlap).
    current = None
    for e in timed:
        if e["start"] <= now and e["end"] > now:
            if current == None or e["end"] < current["end"]:
                current = e

    # Soonest timed event starting after now (used for contiguity + "next").
    next_timed = None
    for e in timed:
        if e["start"] > now:
            if next_timed == None or e["start"] < next_timed["start"]:
                next_timed = e

    if current != None:
        # 2. If the next timed event is contiguous (starts within 5 min of the
        #    current one ending), switch to it 5 min before the current ends.
        if next_timed != None and is_contiguous(current, next_timed):
            if now >= add_seconds(current["end"], -SWITCH_LEAD):
                return next_timed
        return current

    # 3. Next upcoming timed event later today.
    if next_timed != None and same_day(next_timed["start"], now):
        return next_timed

    # No timed event is active or still upcoming today.
    timed_today_existed = False
    for e in timed:
        if same_day(e["start"], now):
            timed_today_existed = True

    # 5. If there were no timed events at all today, fall back to a today
    #    all-day event (e.g. a holiday) before any placeholder/tomorrow logic.
    if not timed_today_existed:
        for e in events:
            if e["all_day"] and same_day(e["start"], now):
                return e

    # 4. No timed events remain today.
    if now.hour < 20:
        # 4a. Before 8 PM → placeholder.
        return None

    # 4b. At or after 8 PM → first timed event of tomorrow (never all-day).
    tomorrow = add_seconds(now, 24 * 60 * 60)
    next_tomorrow = None
    for e in timed:
        if same_day(e["start"], tomorrow) and e["start"] > now:
            if next_tomorrow == None or e["start"] < next_tomorrow["start"]:
                next_tomorrow = e
    return next_tomorrow

def is_contiguous(current, nxt):
    return nxt["start"] <= add_seconds(current["end"], SWITCH_LEAD)

# ---------------------------------------------------------------------------
# iCal parsing
# ---------------------------------------------------------------------------

def fetch_events(tz):
    resp = http.get(ICAL_URL, ttl_seconds = TTL_SECONDS)
    if resp.status_code != 200:
        return []
    return parse_ical(resp.body(), tz)

def parse_ical(body, tz):
    lines = unfold(body)

    events = []
    in_event = False
    summary = ""
    start = None
    end = None
    all_day = False

    for line in lines:
        if line == "BEGIN:VEVENT":
            in_event = True
            summary = ""
            start = None
            end = None
            all_day = False
        elif line == "END:VEVENT":
            if start != None:
                if end == None:
                    end = add_seconds(start, 60 * 60)  # default 1h
                events.append({
                    "summary": summary if summary != "" else "(no title)",
                    "start": start,
                    "end": end,
                    "all_day": all_day,
                })
            in_event = False
        elif in_event:
            name, params, value = split_property(line)
            if name == "SUMMARY":
                summary = unescape(value)
            elif name == "DTSTART":
                start = parse_dt(value, params, tz)
                all_day = is_date_only(value, params)
            elif name == "DTEND":
                end = parse_dt(value, params, tz)

    return events

def unfold(body):
    # iCal folds long lines: a continuation begins with a space or tab.
    out = []
    for line in body.split("\n"):
        line = line.rstrip("\r")
        if len(line) > 0 and (line[0] == " " or line[0] == "\t"):
            if len(out) > 0:
                out[-1] = out[-1] + line[1:]
        else:
            out.append(line)
    return out

def split_property(line):
    # "NAME;params:value" or "NAME:value" -> (NAME, params, value)
    colon = line.find(":")
    if colon < 0:
        return (line, "", "")
    left = line[:colon]
    value = line[colon + 1:]
    semi = left.find(";")
    if semi < 0:
        return (left, "", value)
    return (left[:semi], left[semi + 1:], value)

def is_date_only(value, params):
    return "VALUE=DATE" in params or len(value.strip()) == 8

def parse_dt(value, params, tz):
    # Three iCal forms:
    #   20260618T123000Z   (UTC)
    #   20260618T123000    (floating / TZID in params)
    #   20260618           (all-day, VALUE=DATE)
    value = value.strip()

    if len(value) == 8:
        t = time.parse_time(value, format = "20060102", location = tz)
        return t.in_location(tz)

    if value.endswith("Z"):
        t = time.parse_time(value, format = "20060102T150405Z", location = "UTC")
        return t.in_location(tz)

    loc = tz
    tzid = extract_tzid(params)
    if tzid != "":
        loc = tzid
    t = time.parse_time(value, format = "20060102T150405", location = loc)
    return t.in_location(tz)

def extract_tzid(params):
    for part in params.split(";"):
        if part.startswith("TZID="):
            return part[len("TZID="):]
    return ""

def unescape(s):
    s = s.replace("\\n", " ").replace("\\N", " ")
    s = s.replace("\\,", ",").replace("\\;", ";")
    s = s.replace("\\\\", "\\")
    return s.strip()

# ---------------------------------------------------------------------------
# Formatting helpers
# ---------------------------------------------------------------------------

def add_seconds(t, secs):
    return t + time.parse_duration("%ds" % secs)

def same_day(a, b):
    return a.year == b.year and a.month == b.month and a.day == b.day

def format_date(t):
    return MONTHS[t.month - 1] + " " + str(t.day)

def format_time(t):
    hour = t.hour
    minute = t.minute
    suffix = "am"
    if hour >= 12:
        suffix = "pm"
    h12 = hour % 12
    if h12 == 0:
        h12 = 12
    mm = str(minute)
    if minute < 10:
        mm = "0" + mm
    return "at " + str(h12) + ":" + mm + " " + suffix
