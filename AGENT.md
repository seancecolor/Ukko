# Ukko — Architecture & Agent Specification

## Overview
Ukko is a lightweight, database-less web calendar client for Thundermail CalDAV with automatic Zoom meeting creation, deployed as a single Docker container on Railway.

## Tech Stack & Constraints
- **Backend:** Elixir + Phoenix 1.7+ (API-only mode: `--no-ecto --no-html --no-assets --no-mailer`).
- **HTTP Client:** Use `Req` (`{:req, "~> 0.5.0"}`) for all HTTP/WebDAV/Zoom calls. Do NOT use HTTPoison or Tesla.
- **XML/iCal Parsing:** Use `SweetXml` (`{:sweet_xml, "~> 0.7.4"}`) for CalDAV `<multistatus>` XML responses. Parse/build VEVENT `.ics` payloads directly in Elixir.
- **Database:** NONE (`--no-ecto`). All state lives on the remote CalDAV server. Use an Elixir `Agent` or `ets` table only to cache the Zoom Server-to-Server OAuth token until its `expires_in` timestamp.
- **Frontend:** Located in `/frontend`. Built with Vite + Svelte 5 (or Svelte 4) + `@event-calendar/core` (`@event-calendar/day-grid`, `@event-calendar/time-grid`, `@event-calendar/interaction`).
- **Single-Container Serving:** Vite builds static assets directly to `../priv/static`. Phoenix serves `priv/static/index.html` on the root path `/` and exposes JSON endpoints under `/api/*`.

## Required Environment Variables (configured in Railway)
- `THUNDERMAIL_CALDAV_URL` (e.g., `https://mail.thundermail.com/dav/cal/visitantmedia%40thundermail.com/default/`)
- `THUNDERMAIL_USER`
- `THUNDERMAIL_PASS`
- `ZOOM_ACCOUNT_ID`
- `ZOOM_CLIENT_ID`
- `ZOOM_CLIENT_SECRET`
- `UKKO_PASSCODE` (Simple bearer/cookie passcode so the public Railway URL is protected)
- `SECRET_KEY_BASE`
- `PORT` (Provided automatically by Railway)

## Core API Endpoints to Implement in Phoenix
1. `POST /api/auth` - Validates `UKKO_PASSCODE` and returns a signed Phoenix token or session cookie.
2. `GET /api/events?start=ISO8601&end=ISO8601`
   - Sends a WebDAV `REPORT` (`calendar-query` with `time-range`) to `THUNDERMAIL_CALDAV_URL`.
   - Parses the `.ics` `VEVENT` blocks (`UID`, `SUMMARY`, `DTSTART`, `DTEND`, `DESCRIPTION`, `LOCATION`) and returns a JSON array formatted for `@event-calendar/core`.
3. `POST /api/events`
   - Accepts `{ title, start, end, description, location, create_zoom: boolean }`.
   - If `create_zoom` is true: fetches a Zoom Server-to-Server OAuth token (`grant_type=account_credentials`), creates a meeting via `POST https://api.zoom.us/v2/users/me/meetings`, and sets `location` to the Zoom `join_url` while appending meeting details to `description`.
   - Generates a UUID and sends a `PUT` request with the `.ics` payload to `#{THUNDERMAIL_CALDAV_URL}#{uid}.ics`.
4. `DELETE /api/events/:uid`
   - Sends a `DELETE` request to `#{THUNDERMAIL_CALDAV_URL}#{uid}.ics`.
   