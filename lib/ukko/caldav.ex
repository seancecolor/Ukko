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
             decode_body: false
           ) do
        {:ok, %Req.Response{status: status, body: body}} when status in [200, 207] ->
          events = parse_multistatus_response(to_string(body))
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
    with {:ok, cfg} <- get_config() do
      ics_payload = ICal.build_ics(event_attrs)
      event_url = build_event_url(cfg.url, uid)

      case Req.put(event_url,
             auth: {:basic, "#{cfg.user}:#{cfg.pass}"},
             headers: [{"content-type", "text/calendar; charset=utf-8"}],
             body: ics_payload,
             decode_body: false
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
  Deletes a calendar event on the CalDAV server via `DELETE <caldav_url><uid>.ics`.
  """
  def delete_event(uid) when is_binary(uid) do
    with {:ok, cfg} <- get_config() do
      event_url = build_event_url(cfg.url, uid)

      case Req.delete(event_url,
             auth: {:basic, "#{cfg.user}:#{cfg.pass}"},
             decode_body: false
           ) do
        {:ok, %Req.Response{status: status}} when status in [200, 202, 204] ->
          :ok

        {:ok, %Req.Response{status: 404}} ->
          if String.contains?(uid, "@") do
            alt_url = build_event_url(cfg.url, String.replace(uid, "@", "_"))
            _ = Req.delete(alt_url, auth: {:basic, "#{cfg.user}:#{cfg.pass}"}, decode_body: false)
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
  Parses a CalDAV `<multistatus>` XML body using `SweetXml` and returns a list of parsed VEVENT maps.
  """
  def parse_multistatus_response(xml_body) when is_binary(xml_body) do
    xml_body
    |> xpath(~x"//*[local-name()='calendar-data']"l)
    |> Enum.flat_map(fn node ->
      ics_data =
        node
        |> xpath(~x"./text()"ls)
        |> Enum.join("")

      ICal.parse_vevents(ics_data)
    end)
  rescue
    _ -> []
  catch
    :exit, _ -> []
  end

  @doc """
  Builds the CalDAV `calendar-query` XML payload, including `<C:time-range>` and `<C:expand>`
  when `start_iso` and `end_iso` are given.
  """
  def build_report_xml(start_iso, end_iso) do
    {calendar_data_tag, time_range_tag} =
      case {non_empty(start_iso), non_empty(end_iso)} do
        {nil, nil} ->
          {"<C:calendar-data/>", ""}

        {s, nil} ->
          start_utc = ICal.iso8601_to_ical_utc(s)
          {"<C:calendar-data/>", ~s(<C:time-range start="#{start_utc}"/>)}

        {nil, e} ->
          end_utc = ICal.iso8601_to_ical_utc(e)
          {"<C:calendar-data/>", ~s(<C:time-range end="#{end_utc}"/>)}

        {s, e} ->
          start_utc = ICal.iso8601_to_ical_utc(s)
          end_utc = ICal.iso8601_to_ical_utc(e)

          {
            ~s(<C:calendar-data><C:expand start="#{start_utc}" end="#{end_utc}"/></C:calendar-data>),
            ~s(<C:time-range start="#{start_utc}" end="#{end_utc}"/>)
          }
      end

    """
    <?xml version="1.0" encoding="utf-8" ?>
    <C:calendar-query xmlns:D="DAV:" xmlns:C="urn:ietf:params:xml:ns:caldav">
      <D:prop>
        <D:getetag/>
        #{calendar_data_tag}
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

    clean_uid = String.trim_trailing(uid, ".ics")
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
