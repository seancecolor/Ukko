defmodule Ukko.ICal do
  @moduledoc """
  Parses and builds RFC 5545 iCalendar (.ics) VEVENT payloads.
  """

  @doc """
  Generates a random RFC 4122 v4 UUID string.
  """
  def generate_uid do
    <<u0::48, _::4, u1::12, _::2, u2::62>> = :crypto.strong_rand_bytes(16)

    <<u0::48, 4::4, u1::12, 2::2, u2::62>>
    |> Base.encode16(case: :lower)
    |> then(fn <<a::binary-size(8), b::binary-size(4), c::binary-size(4), d::binary-size(4),
                 e::binary-size(12)>> ->
      "#{a}-#{b}-#{c}-#{d}-#{e}"
    end)
  end

  @doc """
  Parses raw iCalendar text (potentially containing one or more VEVENT blocks)
  into a list of event maps formatted for `@event-calendar/core`.
  """
  def parse_vevents(ics_text) when is_binary(ics_text) do
    unfolded = unfold(ics_text)

    ~r/BEGIN:VEVENT\r?\n(.*?)END:VEVENT/s
    |> Regex.scan(unfolded, capture: :all_but_first)
    |> Enum.map(fn [block] -> parse_vevent_block(block) end)
    |> Enum.reject(&is_nil/1)
  end

  defp unfold(text) do
    String.replace(text, ~r/\r?\n[ \t]/, "")
  end

  defp parse_vevent_block(block) do
    cleaned_block = String.replace(block, ~r/BEGIN:VALARM.*?END:VALARM\r?\n?/s, "")

    props =
      cleaned_block
      |> String.split(~r/\r?\n/, trim: true)
      |> Enum.reduce(%{}, fn line, acc ->
        case split_prop_line(line) do
          {key_and_params, value} ->
            [prop_name | params] = String.split(key_and_params, ";")
            key = String.upcase(prop_name)
            Map.put_new(acc, key, {params, value})

          :error ->
            acc
        end
      end)

    uid = get_prop_text(props, "UID")
    summary = get_prop_text(props, "SUMMARY") || "(No Title)"
    description = get_prop_text(props, "DESCRIPTION") || ""
    location = get_prop_text(props, "LOCATION") || ""
    dtstart = get_prop_datetime(props, "DTSTART")
    dtend = get_prop_datetime(props, "DTEND") || dtstart

    if uid && dtstart do
      %{
        id: "#{uid}::#{dtstart}",
        uid: uid,
        title: summary,
        start: dtstart,
        end: dtend,
        description: description,
        location: location,
        extendedProps: %{
          uid: uid,
          description: description,
          location: location
        }
      }
    else
      nil
    end
  end

  # Splits an iCalendar property line on the first `:` that is outside double quotes `"..."`.
  defp split_prop_line(line) when is_binary(line) do
    do_split_prop_line(line, 0, false)
  end

  defp do_split_prop_line(line, idx, _in_quotes) when idx >= byte_size(line), do: :error

  defp do_split_prop_line(line, idx, in_quotes) do
    case :binary.at(line, idx) do
      ?" ->
        do_split_prop_line(line, idx + 1, not in_quotes)

      ?: when not in_quotes ->
        key_part = binary_part(line, 0, idx)
        val_part = binary_part(line, idx + 1, byte_size(line) - idx - 1)
        {key_part, val_part}

      _ ->
        do_split_prop_line(line, idx + 1, in_quotes)
    end
  end

  defp get_prop_text(props, key) do
    case Map.get(props, key) do
      {_params, value} -> unescape_text(value)
      nil -> nil
    end
  end

  defp get_prop_datetime(props, key) do
    case Map.get(props, key) do
      {_params, value} -> ical_datetime_to_iso8601(String.trim(value))
      nil -> nil
    end
  end

  @doc """
  Converts an iCalendar date/datetime value (e.g. `20261105T143000Z`, `20261105T143000`, `20261105`)
  into an ISO8601 string for `@event-calendar/core`.
  """
  def ical_datetime_to_iso8601(
        <<y::binary-size(4), m::binary-size(2), d::binary-size(2), "T", hh::binary-size(2),
          mm::binary-size(2), ss::binary-size(2), "Z">>
      ) do
    "#{y}-#{m}-#{d}T#{hh}:#{mm}:#{ss}Z"
  end

  def ical_datetime_to_iso8601(
        <<y::binary-size(4), m::binary-size(2), d::binary-size(2), "T", hh::binary-size(2),
          mm::binary-size(2), ss::binary-size(2)>>
      ) do
    "#{y}-#{m}-#{d}T#{hh}:#{mm}:#{ss}"
  end

  def ical_datetime_to_iso8601(<<y::binary-size(4), m::binary-size(2), d::binary-size(2)>>) do
    "#{y}-#{m}-#{d}"
  end

  def ical_datetime_to_iso8601(other), do: other

  @doc """
  Converts an ISO8601 string (or DateTime) into UTC iCalendar timestamp `YYYYMMDDTHHMMSSZ`.
  """
  def iso8601_to_ical_utc(%DateTime{} = dt) do
    dt
    |> DateTime.shift_zone!("Etc/UTC")
    |> Calendar.strftime("%Y%m%dT%H%M%SZ")
  end

  def iso8601_to_ical_utc(iso) when is_binary(iso) do
    trimmed = String.trim(iso)

    cond do
      match?({:ok, _, _}, DateTime.from_iso8601(trimmed)) ->
        {:ok, dt, _offset} = DateTime.from_iso8601(trimmed)
        iso8601_to_ical_utc(dt)

      match?({:ok, _}, NaiveDateTime.from_iso8601(trimmed)) ->
        {:ok, ndt} = NaiveDateTime.from_iso8601(trimmed)
        Calendar.strftime(ndt, "%Y%m%dT%H%M%SZ")

      match?({:ok, _}, NaiveDateTime.from_iso8601(trimmed <> ":00")) ->
        {:ok, ndt} = NaiveDateTime.from_iso8601(trimmed <> ":00")
        Calendar.strftime(ndt, "%Y%m%dT%H%M%SZ")

      match?({:ok, _}, Date.from_iso8601(trimmed)) ->
        {:ok, date} = Date.from_iso8601(trimmed)
        Calendar.strftime(date, "%Y%m%dT000000Z")

      true ->
        trimmed
    end
  end

  @doc """
  Builds an RFC 5545 `.ics` VCALENDAR string for a single event.
  """
  def build_ics(%{uid: uid, title: title, start: start_iso, end: end_iso} = attrs) do
    description = Map.get(attrs, :description) || ""
    location = Map.get(attrs, :location) || ""
    dtstamp = iso8601_to_ical_utc(DateTime.utc_now())
    dtstart = format_dt_prop("DTSTART", start_iso)
    dtend = format_dt_prop("DTEND", end_iso || start_iso)

    lines = [
      "BEGIN:VCALENDAR",
      "VERSION:2.0",
      "PRODID:-//Ukko//CalDAV Client//EN",
      "CALSCALE:GREGORIAN",
      "BEGIN:VEVENT",
      "UID:#{uid}",
      "DTSTAMP:#{dtstamp}",
      dtstart,
      dtend,
      "SUMMARY:#{escape_text(title || "Untitled Event")}",
      "DESCRIPTION:#{escape_text(description)}",
      "LOCATION:#{escape_text(location)}",
      "END:VEVENT",
      "END:VCALENDAR",
      ""
    ]

    Enum.join(lines, "\r\n")
  end

  defp format_dt_prop(prop, iso) when is_binary(iso) do
    trimmed = String.trim(iso)

    if String.length(trimmed) == 10 and match?({:ok, _}, Date.from_iso8601(trimmed)) do
      {:ok, date} = Date.from_iso8601(trimmed)
      "#{prop};VALUE=DATE:#{Calendar.strftime(date, "%Y%m%d")}"
    else
      "#{prop}:#{iso8601_to_ical_utc(trimmed)}"
    end
  end

  defp escape_text(text) when is_binary(text) do
    text
    |> String.replace("\\", "\\\\")
    |> String.replace(";", "\\;")
    |> String.replace(",", "\\,")
    |> String.replace("\r\n", "\\n")
    |> String.replace("\n", "\\n")
  end

  defp unescape_text(text) when is_binary(text) do
    text
    |> String.replace("\\n", "\n")
    |> String.replace("\\N", "\n")
    |> String.replace("\\,", ",")
    |> String.replace("\\;", ";")
    |> String.replace("\\\\", "\\")
  end
end
