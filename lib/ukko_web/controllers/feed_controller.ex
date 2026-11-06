defmodule UkkoWeb.FeedController do
  use UkkoWeb, :controller

  alias Ukko.{CalDAV, Subscriptions}

  @doc """
  GET /api/feed/:token/ukko.ics
  Serves a read-only RFC 5545 `.ics` feed of the user's primary Thundermail calendar
  (excluding subscribed calendars) so external clients like Google Calendar or Apple Calendar
  can subscribe via URL.
  """
  def show(conn, %{"token" => raw_token}) do
    token = String.trim_trailing(raw_token, ".ics")

    if Subscriptions.valid_feed_token?(token) do
      case CalDAV.export_calendar_ics() do
        {:ok, ics_payload} ->
          conn
          |> put_resp_header("content-type", "text/calendar; charset=utf-8")
          |> put_resp_header("cache-control", "no-cache, no-store, must-revalidate")
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

