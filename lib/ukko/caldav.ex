defmodule Ukko.CalDAV do
  @moduledoc """
  Thundermail CalDAV client using `Req` and `SweetXml`.
  """

  import SweetXml
  alias Ukko.{FastCache, ICal}

  @caldav_soft_ttl_seconds 45

  @doc """
  Fetches calendar events between `start_iso` and `end_iso` (optional), backed by
  `Ukko.FastCache` Stale-While-Revalidate ETS caching for sub-millisecond reads and
  instant range navigation. Pass `force_refresh: true` to bypass cache on manual refresh.
  """
  def list_events(start_iso \\ nil, end_iso \\ nil, opts \\ []) do
    force_refresh = Keyword.get(opts, :force_refresh, false)

    case FastCache.fetch_swr(
           FastCache.caldav_key(),
           @caldav_soft_ttl_seconds,
           force_refresh,
           &fetch_all_parsed_calendars/0
         ) do
      {:ok, parsed_calendars} ->
        events =
          Enum.flat_map(parsed_calendars, fn parsed_cal ->
            ICal.expand_parsed_calendar(parsed_cal, start_iso, end_iso)
          end)

        {:ok, events}

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    e -> {:error, {:exception, Exception.message(e)}}
  end

  @doc """
  Warms the primary CalDAV ETS cache on startup or in the background.
  """
  def warm_cache do
    list_events(nil, nil, force_refresh: true)
  end

  defp fetch_all_parsed_calendars do
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
          parsed_calendars =
            body
            |> to_string()
            |> FastCache.extract_xml_tag_bodies("calendar-data")
            |> Enum.reject(fn ics -> String.trim(ics) == "" end)
            |> Enum.map(&ICal.parse_calendar_data/1)
            |> Enum.reject(fn {_vtz, raw_vevents, _overrides} -> raw_vevents == [] end)

          {:ok, parsed_calendars}

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

      case put_raw_ics_to_url(event_url, ics_payload) do
        :ok -> {:ok, uid}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @doc """
  Uploads a raw `.ics` payload directly to a resolved CalDAV resource URL.
  """
  def put_raw_ics_to_url(resource_url, ics_payload)
      when is_binary(resource_url) and is_binary(ics_payload) do
    with {:ok, cfg} <- get_config() do
      case Req.put(resource_url,
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
          unless String.contains?(resource_url, "ukko-subscriptions-config") do
            FastCache.invalidate_caldav()
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
  Fetches a raw `.ics` resource by `uid`, returning `{:ok, raw_ics}`.
  """
  def get_raw_ics(uid) when is_binary(uid) do
    case get_event_resource(uid) do
      {:ok, %{ics: ics}} -> {:ok, ics}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Resolves a CalDAV event by `uid`, trying direct `GET <caldav_url><uid>.ics` first and
  falling back to a `REPORT` UID `prop-filter` lookup when the resource filename differs
  from `<uid>.ics`. Returns `{:ok, %{url: resolved_url, ics: raw_ics}}`.
  """
  def get_event_resource(uid) when is_binary(uid) do
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
          {:ok, %{url: event_url, ics: to_string(body)}}

        {:ok, %Req.Response{status: 404}} ->
          lookup_event_resource_by_uid(cfg, uid)

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
        chunks
        |> Task.async_stream(
          fn {uid, single_ics} ->
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
          end,
          max_concurrency: 6,
          timeout: 35_000,
          on_timeout: :kill_task
        )
        |> Enum.map(fn
          {:ok, res} -> res
          {:exit, reason} -> {:error, {:import_timeout, reason}}
        end)

      FastCache.invalidate_caldav()

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
          FastCache.invalidate_caldav()
          :ok

        {:ok, %Req.Response{status: 404}} ->
          case lookup_event_resource_by_uid(cfg, uid) do
            {:ok, %{url: resolved_url}} ->
              _ =
                Req.delete(resolved_url,
                  auth: {:basic, "#{cfg.user}:#{cfg.pass}"},
                  headers: sched_headers,
                  decode_body: false
                )

              FastCache.invalidate_caldav()
              :ok

            _ ->
              if String.contains?(uid, "@") do
                alt_url = build_event_url(cfg.url, String.replace(uid, "@", "_"))

                _ =
                  Req.delete(alt_url,
                    auth: {:basic, "#{cfg.user}:#{cfg.pass}"},
                    headers: sched_headers,
                    decode_body: false
                  )
              end

              FastCache.invalidate_caldav()
              :ok
          end

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
    ics_blobs = FastCache.extract_xml_tag_bodies(xml_body, "calendar-data")

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
  Parses a CalDAV `<multistatus>` XML body and returns a list of parsed VEVENT maps.
  """
  def parse_multistatus_response(xml_body, start_iso \\ nil, end_iso \\ nil)
      when is_binary(xml_body) do
    xml_body
    |> FastCache.extract_xml_tag_bodies("calendar-data")
    |> Enum.flat_map(fn ics_data ->
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

  defp lookup_event_resource_by_uid(cfg, uid) do
    escaped_uid =
      uid
      |> String.replace("&", "&amp;")
      |> String.replace("<", "&lt;")
      |> String.replace(">", "&gt;")
      |> String.replace("\"", "&quot;")

    xml_body = """
    <?xml version="1.0" encoding="utf-8" ?>
    <C:calendar-query xmlns:D="DAV:" xmlns:C="urn:ietf:params:xml:ns:caldav">
      <D:prop>
        <D:getetag/>
        <C:calendar-data/>
      </D:prop>
      <C:filter>
        <C:comp-filter name="VCALENDAR">
          <C:comp-filter name="VEVENT">
            <C:prop-filter name="UID">
              <C:text-match collation="i;octet">#{escaped_uid}</C:text-match>
            </C:prop-filter>
          </C:comp-filter>
        </C:comp-filter>
      </C:filter>
    </C:calendar-query>
    """

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
           receive_timeout: 20_000,
           connect_options: [timeout: 10_000]
         ) do
      {:ok, %Req.Response{status: status, body: body}} when status in [200, 207] ->
        responses = xpath(to_string(body), ~x"//*[local-name()='response']"l)

        found =
          Enum.find_value(responses, fn resp ->
            href = resp |> xpath(~x"./*[local-name()='href']/text()"s) |> String.trim()
            ics = resp |> xpath(~x".//*[local-name()='calendar-data']/text()"ls) |> Enum.join("")

            if href != "" and String.trim(ics) != "" do
              resolved = URI.merge(URI.parse(cfg.url), href) |> URI.to_string()
              %{url: resolved, ics: ics}
            else
              nil
            end
          end)

        if found, do: {:ok, found}, else: {:error, :not_found}

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, {:caldav_error, status, body}}

      {:error, exception} ->
        {:error, exception}
    end
  rescue
    _ -> {:error, :not_found}
  catch
    :exit, _ -> {:error, :not_found}
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
