# helloCal

A Tidbyt app that displays your Google Calendar events on a 64×32 LED matrix display — with smart refresh, multi-calendar support, and per-device configuration.

---

## What it does

helloCal shows your next calendar event on your Tidbyt display, updating automatically at meaningful moments rather than on a fixed timer. It supports any Google Calendar (not just your primary one), multiple calendars merged per device, and a range of display states that reflect what's actually happening in your day.

### Display states

| State | When it appears |
|---|---|
| **Upcoming event** | Shows event title and start time |
| **Prep time** | Switches to the next event 15 minutes before it starts |
| **Alert state** | Flashing yellow bar when a meeting is imminent (configurable 1–5 minutes) |
| **In progress** | Shows "Now" instead of the start time |
| **All-day event** | Shows "Today" in the time row |
| **After 8pm look-ahead** | Shows tomorrow's first event, or an all-day event with "Tomorrow" |
| **All done** | "ALL DONE FOR TODAY :)" when all meetings are finished |
| **Empty day** | One of six rotating calm phrases when nothing is scheduled |
| **Dec 31** | Fireworks animation after 8pm on New Year's Eve |
| **Welcome** | "Hello :)" when no calendar is configured |

### Event handling

- Recurring events (RRULE), including ordinal weekday rules (e.g. "3rd Monday of the month")
- Extended events (flights, all-day workshops) defer to shorter meetings after a 10-minute persistence window
- Simultaneous events synthesized into "Standup + 2 others", decrementing as each ends
- UID-based deduplication across multiple calendar feeds

---

## How it works

helloCal uses a two-stage smart refresh system instead of a fixed timer:

1. **Heartbeat** (every 5 minutes via cron-job.org): fetches your iCal feed, computes display-change moments for the next 2 hours, and schedules precise one-time jobs on cron-job.org for each moment
2. **On-demand render**: fires only at meaningful moments (prep time, alert, event start, event end) rather than every 5 minutes

A local ledger (`ledger.json`, committed to the repo) tracks scheduled jobs so the system stays within cron-job.org's 100 API calls/day free tier limit.

---

## Community store

helloCal has been submitted to the Tidbyt community store ([PR #3228](https://github.com/tidbyt/community/pull/3228)). The store has been frozen since late 2025 with no merges happening. If and when it reopens, helloCal will be installable directly from the Tidbyt mobile app with no setup required.

In the meantime, self-hosting takes about 30 minutes following the guide below.

---

## Self-hosting

### What you'll need

- A Tidbyt device, set up and connected to Wi-Fi
- A Google Calendar (any calendar, not just your primary one)
- A free GitHub account
- A free [cron-job.org](https://cron-job.org) account

### Step 1 — Get your private calendar link

Google Calendar generates a private URL that gives helloCal read-only access to your calendar without requiring a login.

1. Open Google Calendar on a computer
2. In the left sidebar, hover over the calendar you want to display → click the three-dot menu → **Settings and sharing**
3. Scroll to **Integrate calendar**
4. Copy the **Secret address in iCal format** — it starts with `https://calendar.google.com/calendar/ical/...`

> **Keep this URL private.** Anyone who has it can read your calendar.

### Step 2 — Fork this repository

Click the **Fork** button at the top right of this page. GitHub creates a copy at `github.com/YOUR-USERNAME/tidbyt-cal`.

### Step 3 — Add your secrets

In your forked repo, go to **Settings → Secrets and variables → Actions**, then click **New repository secret** and add each of the following:

| Secret name | What it is | Where to find it |
|---|---|---|
| `ICAL_URL` | Your private calendar URL | Step 1 above |
| `TIDBYT_TOKEN_1` | Your Tidbyt API token | Tidbyt app → your device → scroll to bottom |
| `DISPATCH_TOKEN` | A GitHub personal access token with `repo` scope | GitHub → Settings → Developer settings → Personal access tokens → Generate new token (classic) |
| `CRONJOB_API_KEY` | Your cron-job.org API key | cron-job.org → Settings → API |

### Step 4 — Configure your device

Open `config.json` in your forked repo and update the device entry with your Tidbyt device ID (found in the Tidbyt app under your device settings):

```json
{
  "calendars": [
    {"id": "family", "url_secret": "ICAL_URL"}
  ],
  "devices": [
    {
      "name": "living-room",
      "device_id": "YOUR-DEVICE-ID",
      "token_secret": "TIDBYT_TOKEN_1",
      "calendars": ["family"]
    }
  ]
}
```

Commit the change.

### Step 5 — Set up the heartbeat on cron-job.org

1. Log into [cron-job.org](https://cron-job.org) and click **Create cronjob**
2. Set the **URL** to `https://api.github.com/repos/YOUR-USERNAME/tidbyt-cal/dispatches`
3. Set the execution schedule to **every 5 minutes**
4. Set the request method to **POST**
5. Under **Extended settings**, add these headers:
   ```
   Authorization: Bearer YOUR-DISPATCH-TOKEN
   Accept: application/vnd.github.v3+json
   Content-Type: application/json
   ```
6. Set the request body to:
   ```json
   {"event_type":"tidbyt-check"}
   ```
7. Save the job

### Step 6 — Enable GitHub Actions

In your forked repo, click the **Actions** tab. If prompted, click **I understand my workflows, go ahead and enable them**.

Your display will now update automatically. The first refresh happens within 5 minutes.

---

## Multiple calendars and devices

helloCal supports multiple Google Calendars merged per device, and multiple Tidbyt devices with different calendar subscriptions. Expand `config.json` to add more:

```json
{
  "calendars": [
    {"id": "family",   "url_secret": "ICAL_URL"},
    {"id": "personal", "url_secret": "ICAL_URL_PERSONAL"}
  ],
  "devices": [
    {
      "name": "bedroom",
      "device_id": "YOUR-BEDROOM-DEVICE-ID",
      "token_secret": "TIDBYT_TOKEN_1",
      "calendars": ["family", "personal"]
    },
    {
      "name": "living-room",
      "device_id": "YOUR-LIVING-ROOM-DEVICE-ID",
      "token_secret": "TIDBYT_TOKEN_2",
      "calendars": ["family"]
    }
  ]
}
```

Add a new GitHub Secret for each additional calendar URL.

---

## Staying up to date

To pull in the latest helloCal improvements:

1. Go to your forked repo on GitHub
2. Click **Sync fork → Update branch**

This brings in updates without affecting your `config.json` or secrets.

---

## Getting help

If something isn't working, paste the error into Claude or another AI assistant and describe what step you're on. Most issues are straightforward to diagnose with a fresh pair of eyes.

For bugs or feature requests, open an issue at [github.com/valit/tidbyt-cal/issues](https://github.com/valit/tidbyt-cal/issues).

---

*Built with [Pixlet](https://github.com/tidbyt/pixlet) (Starlark) · Python · Bash · GitHub Actions · [cron-job.org](https://cron-job.org)*
