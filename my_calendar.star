"""
my_calendar.star — Tidbyt/Pixlet app

Shows the next relevant event from a private Google Calendar iCal feed,
with a pixel-precise three-row layout on the 64x32 display.

LAYOUT (64x32, origin top-left)
  ROW 1  calendar3.png icon (8x8) at x=2,y=2  +  date in magenta
  ROW 2  event title (white, as written), marquee-scrolled full width
  ROW 3  time in yellow ("At H:MM am/pm" or "All day"), near the bottom

  All text uses the standard Tidbyt font "tb-8" (baseline = box top + 7,
  lowest glyph pixel = box top + 6).

  Static content keeps a 3px margin on every edge; the Row 2 title marquee is
  exempt and runs full width edge to edge.
    - Icon: 8x8 at x=3, y=3                            -> icon bottom edge y=11
    - Date: x=14 (3px gap), baseline 1px above icon bottom edge (y=10) -> box top y=3
    - Row 2 title: full-width marquee                  -> y=14
    - Row 3 bottom: lowest pixel at row 28 (3px gap)   -> text box top y=22

  Note: Pixlet runs in a sandbox with no filesystem access, so the
  8x8 "calendar3.png" in this folder is embedded below as base64 and
  decoded at render time for render.Image.
"""

load("render.star", "render")
load("http.star", "http")
load("time.star", "time")
load("encoding/base64.star", "base64")
load("schema.star", "schema")

# The private iCal feed URL is NOT stored in this file. It is supplied at
# runtime via Pixlet config: config.get("ical_url"). In CI, push.sh passes it
# from the ICAL_URL GitHub Secret. For local preview, pass it on the command
# line, e.g.:  pixlet render my_calendar.star ical_url="https://..."

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

# tb-8 per-character advance widths in pixels (measured empirically). Used to
# decide whether a title fits without scrolling. A rendered string's pixel
# width = sum(advances) - 1.
CHAR_ADV = {"!": 2, "'": 2, ".": 2, ":": 2, " ": 3, "(": 3, ")": 3, ",": 3, "+": 4, "-": 4, "?": 4, "I": 4, "J": 4, "T": 4, "c": 4, "i": 4, "j": 4, "l": 4, "s": 4, "v": 4, "&": 5, "/": 5, "0": 5, "1": 5, "2": 5, "3": 5, "4": 5, "5": 5, "6": 5, "7": 5, "8": 5, "9": 5, "A": 5, "B": 5, "C": 5, "D": 5, "E": 5, "F": 5, "G": 5, "H": 5, "K": 5, "L": 5, "N": 5, "O": 5, "P": 5, "Q": 5, "R": 5, "S": 5, "U": 5, "X": 5, "Z": 5, "a": 5, "b": 5, "d": 5, "e": 5, "f": 5, "g": 5, "h": 5, "k": 5, "n": 5, "o": 5, "p": 5, "q": 5, "r": 5, "t": 5, "u": 5, "x": 5, "y": 5, "z": 5, "M": 6, "V": 6, "W": 6, "Y": 6, "m": 6, "w": 6}
DEFAULT_ADV = 6  # unknown chars: assume widest, so we never under-estimate & clip
TITLE_STATIC_MAX = 61  # px; title <= this fits at x=3 without clipping -> static

def text_width(s):
    if len(s) == 0:
        return 0
    w = 0
    for i in range(len(s)):
        w += CHAR_ADV.get(s[i], DEFAULT_ADV)
    return w - 1

# When True, the app pretends every day is December 31st so the New Year's Eve
# easter egg can be previewed on any date. Must stay False in production.
TEST_FORCE_DEC31 = False

def is_new_years_eve(now):
    # New Year's Eve easter egg trigger (Dec 31). TEST_FORCE_DEC31 forces it on
    # for previewing regardless of the real date.
    if TEST_FORCE_DEC31:
        return True
    return now.month == 12 and now.day == 31

# 8x8 calendar3.png (same image as the file in this folder), base64-encoded.
CALENDAR_PNG = base64.decode("iVBORw0KGgoAAAANSUhEUgAAAAgAAAAICAYAAADED76LAAAAQElEQVQYlWP8//8/AwQw/mdg+M+IzmaC8EECUBqZDVMKNQIrYAERDx88wCopr6AAtQIPoFwBI9ibMJejg///GQEXFxYMoIno4wAAAABJRU5ErkJggg==")

# 23x23 fireworks easter-egg sprite frames (fw_fw1..fw_fw4.png in this folder),
# base64-encoded. Cycled by render.Animation on the New Year's Eve screen.
FW1 = base64.decode("iVBORw0KGgoAAAANSUhEUgAAABcAAAAXCAYAAADgKtSgAAAAJElEQVR42mNgGAWjYBQME/D/ddN/mhkMBrS0YDT+RsEoGC4AANDQEalSyfH5AAAAAElFTkSuQmCC")
FW2 = base64.decode("iVBORw0KGgoAAAANSUhEUgAAABcAAAAXCAYAAADgKtSgAAAAOklEQVR42mNgGAWjYBQw/P+06j8hNlUsQKep64vXTf+pHixgDDQYDEA0VGxwu5ymYU7z1DIKRsEQBwCfH0tJQ7rxqQAAAABJRU5ErkJggg==")
FW3 = base64.decode("iVBORw0KGgoAAAANSUhEUgAAABcAAAAXCAYAAADgKtSgAAAAfUlEQVR42mNgGBHgV+aW/0PT8P+fVlFu+P9puv9JMTzqxLP/FFuAzXCSDUY3jBBNlXDGxabY5eiYehGMZgjJhoIiEIyxuBLu0tdNOH0CwhWXKsCYvi4fkDCnS2qhajrHFjHYDCO5MMMV47hcSpXSkiqpBBcgu5AacMMHFQAALWftMOh4WMAAAAAASUVORK5CYII=")
FW4 = base64.decode("iVBORw0KGgoAAAANSUhEUgAAABcAAAAXCAYAAADgKtSgAAAAV0lEQVR42mNgGCyg1iTqxNA0nGJQ7y1Glut0U4pP0MQCog0eBcMAgFIHuUkQHdhk2pwA4dFQHSkAV2zXV4aeoKgoJjYZoRdWZJX1dKsgQK6lVmYb3OU2ANIcIx0TOc/2AAAAAElFTkSuQmCC")

def main(config):
    tz = LOCATION
    now = time.now().in_location(tz)

    ical_url = config.get("ical_url")
    if not ical_url:
        return render_message("Set ICAL_URL")

    events = fetch_events(tz, ical_url)
    event = select_event(events, now, tz)

    if event == None:
        return render_no_events()

    return render_event(event)

def get_schema():
    # Exposes the iCal URL as a config field. In `pixlet serve`, this renders an
    # input box in the browser preview. The field id "ical_url" matches the key
    # the app reads (config.get("ical_url")) and the value push.sh passes in CI
    # (ical_url="$ICAL_URL"), so serve and the workflow stay in sync.
    return schema.Schema(
        version = "1",
        fields = [
            schema.Text(
                id = "ical_url",
                name = "iCal URL",
                desc = "Private Google Calendar iCal feed URL (.ics)",
                icon = "calendar",
            ),
        ],
    )

# ---------------------------------------------------------------------------
# Rendering
# ---------------------------------------------------------------------------

def title_row(title):
    # The Row 2 title. If it fits within the static width, render plain text at
    # the 3px left margin (like the other static rows). Only when it's too wide
    # do we fall back to a full-width, edge-to-edge scrolling marquee.
    if text_width(title) <= TITLE_STATIC_MAX:
        return render.Padding(
            pad = (3, 14, 0, 0),
            child = render.Text(content = title, color = WHITE, font = FONT),
        )
    return render.Padding(
        pad = (0, 14, 0, 0),
        child = render.Marquee(
            width = 64,
            child = render.Text(content = title, color = WHITE, font = FONT),
        ),
    )

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
                    pad = (3, 3, 0, 0),
                    child = render.Image(src = CALENDAR_PNG, width = 8, height = 8),
                ),
                # ROW 1 — date text, 2px right of the icon
                render.Padding(
                    pad = (14, 3, 0, 0),
                    child = render.Text(content = date_str, color = PINK, font = FONT),
                ),

                # ROW 2 — title. Static with a 3px left margin if it fits;
                # full-width scrolling marquee only when it's too long.
                title_row(title),

                # ROW 3 — time, 2px from the left
                render.Padding(
                    pad = (3, 22, 0, 0),
                    child = render.Text(content = time_str, color = YELLOW, font = FONT),
                ),
            ],
        ),
    )

def render_message(msg):
    # Simple centered message (e.g. when the iCal URL config is missing).
    return render.Root(
        child = render.Box(
            width = 64,
            height = 32,
            color = BLACK,
            child = render.WrappedText(content = msg, color = WHITE, font = FONT, align = "center", width = 60),
        ),
    )

def render_no_events():
    # Same 3-row layout as the main display: icon + today's date on top, then
    # two static yellow lines (no marquee).
    now = time.now().in_location(LOCATION)
    date_str = format_date(now)

    # New Year's Eve easter egg: same middle line, year-stamped bottom line
    # (year pulled dynamically from today's date, e.g. "FOR 2026").
    nye = is_new_years_eve(now)
    middle_line = "ALL DONE"
    bottom_line = "FOR " + str(now.year) + "!!" if nye else "FOR TODAY :)"

    kids = [
        render.Box(width = 64, height = 32, color = BLACK),

        # ROW 1 — calendar icon at (2, 2) + today's date
        render.Padding(
            pad = (3, 3, 0, 0),
            child = render.Image(src = CALENDAR_PNG, width = 8, height = 8),
        ),
        render.Padding(
            pad = (14, 3, 0, 0),
            child = render.Text(content = date_str, color = PINK, font = FONT),
        ),

        # ROW 2 — static line, 2px from the left
        render.Padding(
            pad = (3, 14, 0, 0),
            child = render.Text(content = middle_line, color = YELLOW, font = FONT),
        ),

        # ROW 3 — static line, 2px from the left
        render.Padding(
            pad = (3, 22, 0, 0),
            child = render.Text(content = bottom_line, color = YELLOW, font = FONT),
        ),
    ]

    # Easter egg flourish: an animated fireworks burst on the right side,
    # nudged slightly above center (23x23 sprite at x=42, y=2 -> center ~(53,13)).
    # The text keeps its 3px margins; the firework is decorative and may run to
    # the right edge. Frames cycle spark -> small burst -> big burst -> fading,
    # with a short blank gap, then loop.
    if nye:
        kids.append(render.Padding(
            pad = (42, 2, 0, 0),
            child = render.Animation(children = [
                render.Image(src = FW1, width = 23, height = 23),
                render.Image(src = FW2, width = 23, height = 23),
                render.Image(src = FW3, width = 23, height = 23),
                render.Image(src = FW3, width = 23, height = 23),
                render.Image(src = FW4, width = 23, height = 23),
                render.Image(src = FW4, width = 23, height = 23),
                render.Box(width = 23, height = 23),
                render.Box(width = 23, height = 23),
            ]),
        ))

    return render.Root(child = render.Stack(children = kids), delay = 150)

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

    # Easter egg: on Dec 31, stay on the no-events screen through midnight
    # instead of jumping ahead to tomorrow's (next year's) first event.
    if is_new_years_eve(now):
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

def fetch_events(tz, ical_url):
    resp = http.get(ical_url, ttl_seconds = TTL_SECONDS)
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
    # e.g. "JUN 19" — month abbreviation, then day number.
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
    return str(h12) + ":" + mm + " " + suffix
