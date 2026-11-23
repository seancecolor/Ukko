defmodule UkkoWeb.FeedController do
  use UkkoWeb, :controller

  alias Ukko.{CalDAV, Subscriptions}

  @doc """
  GET /api/feed/:token/ukko.ics
  Serves a live, uncached RFC 5545 `.ics` feed of the user's primary Thundermail calendar
  (excluding subscribed calendars) so external clients like Google Calendar or Apple Calendar
  always see event edits, reschedules, and deletions as soon as they poll.
  """
  def show(conn, %{"token" => raw_token}) do
    token = String.trim_trailing(raw_token, ".ics")

    if Subscriptions.valid_feed_token?(token) do
      case CalDAV.export_calendar_ics() do
        {:ok, ics_payload} ->
          etag =
            :crypto.hash(:sha256, ics_payload)
            |> Base.encode16(case: :lower)
            |> binary_part(0, 24)

          conn
          |> put_resp_header("content-type", "text/calendar; charset=utf-8")
          |> put_resp_header("cache-control", "no-cache, no-store, max-age=0, must-revalidate")
          |> put_resp_header("pragma", "no-cache")
          |> put_resp_header("expires", "0")
          |> put_resp_header("cdn-cache-control", "no-store")
          |> put_resp_header("surrogate-control", "no-store")
          |> put_resp_header("etag", ~s("#{etag}"))
          |> put_resp_header("content-disposition", ~s(inline; filename="ukko.ics"))
          |> send_resp(200, ics_payload)

        {:error, _reason} ->
          conn
          |> put_resp_content_type("text/plain")
          |> send_resp(502, "Failed to fetch upstream CalDAV calendar.")
      end
    else
      conn
      |> put_resp_content_type("text/plain")
      |> send_resp(404, "Calendar feed not found.")
    end
  end
end
