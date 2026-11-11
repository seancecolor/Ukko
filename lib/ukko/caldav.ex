defmodule Ukko.CalDAV do
  @moduledoc """
  Thundermail CalDAV client using `Req` and `SweetXml`.
  """

  import SweetXml
  alias Ukko.ICal

  @doc """
  Fetches calendar events between `start_iso` and `end_iso` (optional) via a WebDAV `REPORT`
  request (`calendar-query`), parses the XML `<multistatus>` response with `SweetXml`,
  and extracts all `.ics` `VEVENT` items.
  """
  def list_events(start_iso \\ nil, end_iso \\ nil) do
    with {:ok, cfg} <- get_config() do
      xml_body = build_report_xml(start_iso, end_iso)

      case Req.request(
             method: "REPORT",
             url: cfg.url,
             auth: {:basic, "#{cfg.user}:#{cfg.pass}"},
             headers: [
               {"depth", "1"},
               {"content-type", "application/xml; charset=utf-8"}
             ],
             body: xml_body,
             decode_body: false,
             receive_timeout: 30_000,
             connect_options: [timeout: 15_000],
             retry: :transient,
             max_retries: 2
           ) do
        {:ok, %Req.Response{status: status, body: body}} when status in [200, 207] ->
          events = parse_multistatus_response(to_string(body), start_iso, end_iso)
          {:ok, events}

        {:ok, %Req.Response{status: status, body: body}} ->
          {:error, {:caldav_error, status, body}}

        {:error, exception} ->
          {:error, exception}
      end
    end
  rescue
    e -> {:error, {:exception, Exception.message(e)}}
  end

  @doc """
  Creates or updates a calendar event on the CalDAV server via `PUT <caldav_url><uid>.ics`.
  """
  def put_event(%{uid: uid} = event_attrs) do
    ics_payload = ICal.build_ics(event_attrs)
    put_raw_ics(uid, ics_payload)
  end

  @doc """
  Uploads a raw `.ics` payload to `<caldav_url><uid>.ics`.
  """
  def put_raw_ics(uid, ics_payload) when is_binary(uid) and is_binary(ics_payload) do
    with {:ok, cfg} <- get_config() do
      event_url = build_event_url(cfg.url, uid)

      case Req.put(event_url,
             auth: {:basic, "#{cfg.user}:#{cfg.pass}"},
             headers: [{"content-type", "text/calendar; charset=utf-8"}],
             body: ics_payload,
             decode_body: false,
             receive_timeout: 30_000,
             connect_options: [timeout: 15_000],
             retry: :transient,
             max_retries: 2
           ) do
        {:ok, %Req.Response{status: status}} when status in [200, 201, 204] ->
          {:ok, uid}

        {:ok, %Req.Response{status: status, body: body}} ->
          {:error, {:caldav_error, status, body}}

        {:error, exception} ->
          {:error, exception}
      end
    end
  rescue
    e -> {:error, {:exception, Exception.message(e)}}
  end

  @doc """
  Fetches a raw `.ics` resource by `uid` from `<caldav_url><uid>.ics`.
  """
  def get_raw_ics(uid) when is_binary(uid) do
    with {:ok, cfg} <- get_config() do
      event_url = build_event_url(cfg.url, uid)

      case Req.get(event_url,
             auth: {:basic, "#{cfg.user}:#{cfg.pass}"},
             decode_body: false,
             receive_timeout: 20_000,
             connect_options: [timeout: 10_000],
             retry: :transient,
             max_retries: 1
           ) do
        {:ok, %Req.Response{status: 200, body: body}} ->
          {:ok, to_string(body)}

        {:ok, %Req.Response{status: 404}} ->
          {:error, :not_found}

        {:ok, %Req.Response{status: status, body: body}} ->
          {:error, {:caldav_error, status, body}}

        {:error, exception} ->
          {:error, exception}
      end
    end
  rescue
    e -> {:error, {:exception, Exception.message(e)}}
  end

  @doc """
  Imports a raw `.ics` string containing one or more VEVENTs into the CalDAV calendar.
  """
  def import_ics(ics_text) when is_binary(ics_text) do
    chunks = ICal.split_ics_by_uid(ics_text)

    if chunks == [] do
      {:error, :no_events_found}
    else
      results =
        Enum.map(chunks, fn {uid, single_ics} ->
          case put_raw_ics(uid, single_ics) do
            {:ok, ^uid} ->
              {:ok, uid}

            {:error, _} ->
              # Fallback: rebuild normalized .ics if server rejected vendor properties
              case ICal.parse_vevents(single_ics) do
                [ev | _] ->
                  put_event(%{
                    uid: uid,
                    title: ev.title,
                    start: ev.start,
                    end: ev.end,
                    description: ev.description,
                    location: ev.location
                  })

                [] ->
                  {:error, :invalid_event}
              end
          end
        end)

      case Enum.find(results, &match?({:error, _}, &1)) do
        nil ->
          parsed_events = ICal.parse_vevents(ics_text)
          {:ok, parsed_events}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @doc """
  Deletes a calendar event on the CalDAV server via `DELETE <caldav_url><uid>.ics`.
  Explicitly includes RFC 6638 `Schedule-Reply: T` so Thundermail/Stalwart sends
  iTIP/iMIP cancellation notices to attendees (or a Declined reply if deleting an invite).
  """
  def delete_event(uid) when is_binary(uid) do
    with {:ok, cfg} <- get_config() do
      event_url = build_event_url(cfg.url, uid)
      sched_headers = [{"schedule-reply", "T"}]

      case Req.delete(event_url,
             auth: {:basic, "#{cfg.user}:#{cfg.pass}"},
             headers: sched_headers,
             decode_body: false,
             receive_timeout: 25_000,
             connect_options: [timeout: 15_000],
             retry: :transient,
             max_retries: 2
           ) do
        {:ok, %Req.Response{status: status}} when status in [200, 202, 204] ->
          :ok

        {:ok, %Req.Response{status: 404}} ->
          if String.contains?(uid, "@") do
            alt_url = build_event_url(cfg.url, String.replace(uid, "@", "_"))

            _ =
              Req.delete(alt_url,
                auth: {:basic, "#{cfg.user}:#{cfg.pass}"},
                headers: sched_headers,
                decode_body: false
              )
          end

          :ok

        {:ok, %Req.Response{status: status, body: body}} ->
          {:error, {:caldav_error, status, body}}

        {:error, exception} ->
          {:error, exception}
      end
    end
  rescue
    e -> {:error, {:exception, Exception.message(e)}}
  end

  @doc """
  Exports the user's entire primary Thundermail CalDAV calendar as a single RFC 5545
  `VCALENDAR` (`.ics`) string (excluding subscribed calendars and internal Ukko config).
  """
  def export_calendar_ics do
    with {:ok, cfg} <- get_config() do
      xml_body = build_report_xml(nil, nil)

      case Req.request(
             method: "REPORT",
             url: cfg.url,
             auth: {:basic, "#{cfg.user}:#{cfg.pass}"},
             headers: [
               {"depth", "1"},
               {"content-type", "application/xml; charset=utf-8"}
             ],
             body: xml_body,
             decode_body: false,
             receive_timeout: 30_000,
             connect_options: [timeout: 15_000],
             retry: :transient,
             max_retries: 2
           ) do
        {:ok, %Req.Response{status: status, body: body}} when status in [200, 207] ->
          {:ok, build_combined_ics(to_string(body))}

        {:ok, %Req.Response{status: status, body: body}} ->
          {:error, {:caldav_error, status, body}}

        {:error, exception} ->
          {:error, exception}
      end
    end
  rescue
    e -> {:error, {:exception, Exception.message(e)}}
  end

  @doc """
  Combines all `<calendar-data>` blocks from a CalDAV `<multistatus>` XML response into a
  single RFC 5545 `VCALENDAR` document.
  """
  def build_combined_ics(xml_body) when is_binary(xml_body) do
    ics_blobs =
      xml_body
      |> xpath(~x"//*[local-name()='calendar-data']"l)
      |> Enum.map(fn node ->
        node
        |> xpath(~x"./text()"ls)
        |> Enum.join("")
      end)

    vtimezones =
      ics_blobs
      |> Enum.flat_map(fn ics ->
        ~r/BEGIN:VTIMEZONE\r?\n.*?END:VTIMEZONE/s
        |> Regex.scan(ics)
        |> Enum.map(fn [block] -> String.trim(block) end)
      end)
      |> Enum.uniq_by(fn vt_block ->
        case Regex.run(~r/^TZID(?:;[^:]*)?:(.*)$/m, vt_block, capture: :all_but_first) do
          [tzid] -> String.trim(tzid)
          _ -> vt_block
        end
      end)

    vevents =
      ics_blobs
      |> Enum.flat_map(fn ics ->
        ~r/BEGIN:VEVENT\r?\n.*?END:VEVENT/s
        |> Regex.scan(ics)
        |> Enum.map(fn [block] -> String.trim(block) end)
      end)
      |> Enum.reject(fn vevent_block ->
        String.contains?(vevent_block, "UID:ukko-subscriptions-config")
      end)

    lines =
      [
        "BEGIN:VCALENDAR",
        "VERSION:2.0",
        "PRODID:-//Ukko Cal//CalDAV Feed//EN",
        "CALSCALE:GREGORIAN",
        "METHOD:PUBLISH",
        "X-WR-CALNAME:Ukko Calendar",
        "X-WR-TIMEZONE:America/Los_Angeles"
      ] ++ vtimezones ++ vevents ++ ["END:VCALENDAR", ""]

    Enum.join(lines, "\r\n")
  rescue
    _ ->
      "BEGIN:VCALENDAR\r\nVERSION:2.0\r\nPRODID:-//Ukko Cal//CalDAV Feed//EN\r\nEND:VCALENDAR\r\n"
  catch
    :exit, _ ->
      "BEGIN:VCALENDAR\r\nVERSION:2.0\r\nPRODID:-//Ukko Cal//CalDAV Feed//EN\r\nEND:VCALENDAR\r\n"
  end

  @doc """
  Parses a CalDAV `<multistatus>` XML body using `SweetXml` and returns a list of parsed VEVENT maps.
  """
  def parse_multistatus_response(xml_body, start_iso \\ nil, end_iso \\ nil)
      when is_binary(xml_body) do
    xml_body
    |> xpath(~x"//*[local-name()='calendar-data']"l)
    |> Enum.flat_map(fn node ->
      ics_data =
        node
        |> xpath(~x"./text()"ls)
        |> Enum.join("")

      ICal.parse_vevents(ics_data, start_iso, end_iso)
    end)
  rescue
    _ -> []
  catch
    :exit, _ -> []
  end

  @doc """
  Builds the CalDAV `calendar-query` XML payload with `<C:time-range>` when `start_iso`
  or `end_iso` are given.
  """
  def build_report_xml(start_iso, end_iso) do
    time_range_tag =
      case {non_empty(start_iso), non_empty(end_iso)} do
        {nil, nil} ->
          ""

        {s, nil} ->
          start_utc = ICal.iso8601_to_ical_utc(s)
          ~s(<C:time-range start="#{start_utc}"/>)

        {nil, e} ->
          end_utc = ICal.iso8601_to_ical_utc(e)
          ~s(<C:time-range end="#{end_utc}"/>)

        {s, e} ->
          start_utc = ICal.iso8601_to_ical_utc(s)
          end_utc = ICal.iso8601_to_ical_utc(e)
          ~s(<C:time-range start="#{start_utc}" end="#{end_utc}"/>)
      end

    """
    <?xml version="1.0" encoding="utf-8" ?>
    <C:calendar-query xmlns:D="DAV:" xmlns:C="urn:ietf:params:xml:ns:caldav">
      <D:prop>
        <D:getetag/>
        <C:calendar-data/>
      </D:prop>
      <C:filter>
        <C:comp-filter name="VCALENDAR">
          <C:comp-filter name="VEVENT">
            #{time_range_tag}
          </C:comp-filter>
        </C:comp-filter>
      </C:filter>
    </C:calendar-query>
    """
  end

  defp non_empty(nil), do: nil

  defp non_empty(str) when is_binary(str) do
    trimmed = String.trim(str)
    if trimmed == "", do: nil, else: trimmed
  end

  defp build_event_url(base_url, uid) do
    normalized_base =
      if String.ends_with?(base_url, "/"), do: base_url, else: base_url <> "/"

    clean_uid =
      uid
      |> String.trim_trailing(".ics")
      |> String.replace("@caldav-import", "_caldav-import")

    "#{normalized_base}#{URI.encode(clean_uid)}.ics"
  end

  defp get_config do
    url = non_empty(Application.get_env(:ukko, :thundermail_caldav_url))
    user = non_empty(Application.get_env(:ukko, :thundermail_user))
    pass = non_empty(Application.get_env(:ukko, :thundermail_pass))

    if is_nil(url) or is_nil(user) or is_nil(pass) do
      {:error, :missing_caldav_credentials}
    else
      {:ok, %{url: url, user: user, pass: pass}}
    end
  end
end
