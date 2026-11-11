defmodule Ukko.ICal do
  @moduledoc """
  Parses and builds RFC 5545 iCalendar (.ics) VEVENT payloads, including
  VTIMEZONE / TZID timezone conversion and RRULE / EXDATE / RECURRENCE-ID expansion.
  """

  @internal_config_uid "ukko-subscriptions-config"

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
  Parses raw iCalendar text (potentially containing VTIMEZONE and one or more VEVENT blocks)
  into a list of event maps formatted for `@event-calendar/core`.

  Optionally expands recurring events (`RRULE`) and filters events to `[range_start_iso, range_end_iso]`.
  """
  def parse_vevents(ics_text, range_start_iso \\ nil, range_end_iso \\ nil, extra_meta \\ %{})
      when is_binary(ics_text) do
    ics_text
    |> parse_calendar_data()
    |> expand_parsed_calendar(range_start_iso, range_end_iso, extra_meta)
  end

  @doc """
  Parses raw `.ics` text once into `{vtimezones, raw_vevents, recurrence_overrides}` so that
  large subscribed calendars (such as Google Calendar feeds) can be cached in memory and
  expanded for any date window in milliseconds.
  """
  def parse_calendar_data(ics_text) when is_binary(ics_text) do
    unfolded = unfold(ics_text)
    vtimezones = parse_vtimezones(unfolded)

    raw_vevents =
      unfolded
      |> extract_component_blocks("VEVENT")
      |> Enum.map(fn block -> parse_raw_vevent(block, vtimezones) end)
      |> Enum.reject(&is_nil/1)

    recurrence_overrides =
      Enum.reduce(raw_vevents, %{}, fn ev, acc ->
        case ev.recurrence_id do
          nil ->
            acc

          rec_info ->
            rec_key = recurrence_match_key(rec_info)
            Map.update(acc, ev.uid, MapSet.new([rec_key]), &MapSet.put(&1, rec_key))
        end
      end)

    {vtimezones, raw_vevents, recurrence_overrides}
  end

  @doc """
  Expands a pre-parsed `{vtimezones, raw_vevents, recurrence_overrides}` tuple for a target
  `[range_start_iso, range_end_iso]` window.
  """
  def expand_parsed_calendar(
        {vtimezones, raw_vevents, recurrence_overrides},
        range_start_iso \\ nil,
        range_end_iso \\ nil,
        extra_meta \\ %{}
      ) do
    {range_start_dt, range_end_dt} = parse_filter_range(range_start_iso, range_end_iso)

    master_rrules =
      Enum.reduce(raw_vevents, %{}, fn ev, acc ->
        if map_size(ev.rrule) > 0 and is_nil(ev.recurrence_id) do
          Map.put(acc, ev.uid, Map.get(ev, :rrule_raw, ""))
        else
          acc
        end
      end)

    raw_vevents
    |> Enum.flat_map(fn ev ->
      if map_size(ev.rrule) == 0 and not single_event_in_rough_range?(ev.dtstart, ev.dtend, range_start_dt, range_end_dt) do
        []
      else
        override_keys = Map.get(recurrence_overrides, ev.uid, MapSet.new())
        ev_meta = Map.put(extra_meta, :series_rrule, Map.get(master_rrules, ev.uid))
        expand_vevent(ev, vtimezones, range_start_dt, range_end_dt, override_keys, ev_meta)
      end
    end)
    |> filter_by_range(range_start_dt, range_end_dt)
  end

  defp single_event_in_rough_range?(_dtstart, _dtend, nil, nil), do: true

  defp single_event_in_rough_range?(dtstart, dtend, range_start_dt, range_end_dt) do
    s_utc = dt_info_to_rough_utc(dtstart, false)
    e_utc = dt_info_to_rough_utc(dtend || dtstart, true) || s_utc

    after_start =
      case {range_start_dt, e_utc} do
        {%DateTime{} = rs, %DateTime{} = ee} ->
          DateTime.compare(DateTime.add(ee, 86_400, :second), rs) == :gt

        _ ->
          true
      end

    before_end =
      case {range_end_dt, s_utc} do
        {%DateTime{} = re, %DateTime{} = es} ->
          DateTime.compare(DateTime.add(es, -86_400, :second), re) == :lt

        _ ->
          true
      end

    after_start and before_end
  end

  defp dt_info_to_rough_utc({:date, %Date{} = d}, is_end) do
    base = DateTime.new!(d, ~T[00:00:00], "Etc/UTC")
    if is_end, do: DateTime.add(base, 86_400, :second), else: base
  end

  defp dt_info_to_rough_utc({_, %DateTime{} = dt, _, _}, _is_end), do: dt
  defp dt_info_to_rough_utc(_, _), do: nil

  defp extract_component_blocks(text, comp_name) do
    begin_marker = "BEGIN:" <> comp_name
    end_marker = "END:" <> comp_name

    case :binary.split(text, begin_marker, [:global]) do
      [_header] ->
        []

      [_header | chunks] ->
        Enum.reduce(chunks, [], fn chunk, acc ->
          case :binary.split(chunk, end_marker) do
            [inner | _] -> [inner | acc]
            _ -> acc
          end
        end)
        |> Enum.reverse()
    end
  end

  @doc """
  Splits a raw `.ics` file containing one or more `VEVENT` blocks into `{uid, ics_string}` tuples
  grouped by `UID`, preserving any `VTIMEZONE` blocks from the source `.ics`.
  """
  def split_ics_by_uid(ics_text) when is_binary(ics_text) do
    unfolded = unfold(ics_text)

    vtimezone_blocks =
      ~r/BEGIN:VTIMEZONE\r?\n.*?END:VTIMEZONE/s
      |> Regex.scan(unfolded)
      |> Enum.map(fn [b] -> String.trim(b) end)

    vevent_blocks =
      ~r/BEGIN:VEVENT\r?\n(.*?)END:VEVENT/s
      |> Regex.scan(unfolded, capture: :all_but_first)
      |> Enum.map(fn [inner] -> String.trim(inner) end)

    grouped =
      Enum.reduce(vevent_blocks, %{}, fn inner, acc ->
         {props, _exdates} = extract_block_props(inner)
        uid = get_prop_text(props, "UID") || generate_uid()

        if uid == @internal_config_uid do
          acc
        else
          ensured_inner =
            if get_prop_text(props, "UID") do
              inner
            else
              "UID:#{uid}\r\n" <> inner
            end

          full_vevent = "BEGIN:VEVENT\r\n" <> ensured_inner <> "\r\nEND:VEVENT"
          Map.update(acc, uid, [full_vevent], fn list -> list ++ [full_vevent] end)
        end
      end)

    Enum.map(grouped, fn {uid, vevents} ->
      lines =
        [
          "BEGIN:VCALENDAR",
          "VERSION:2.0",
          "PRODID:-//Ukko//CalDAV Client//EN",
          "CALSCALE:GREGORIAN"
        ] ++ vtimezone_blocks ++ vevents ++ ["END:VCALENDAR", ""]

      {uid, Enum.join(lines, "\r\n")}
    end)
  end

  defp unfold(text) do
    String.replace(text, ~r/\r?\n[ \t]/, "")
  end

  # --- VTIMEZONE Parsing & Resolution ---

  defp parse_vtimezones(unfolded_ics) do
    unfolded_ics
    |> extract_component_blocks("VTIMEZONE")
    |> Enum.reduce(%{}, fn vt_block, acc ->
      tzid =
        case Regex.run(~r/^TZID(?:;[^:]*)?:(.*)$/m, vt_block, capture: :all_but_first) do
          [raw_tzid] -> clean_tzid(raw_tzid)
          _ -> nil
        end

      if tzid do
        standard_rules = parse_tz_subblocks(vt_block, "STANDARD", :standard)
        daylight_rules = parse_tz_subblocks(vt_block, "DAYLIGHT", :daylight)
        Map.put(acc, tzid, %{tzid: tzid, standard: standard_rules, daylight: daylight_rules})
      else
        acc
      end
    end)
  end

  defp parse_tz_subblocks(vt_block, tag, kind) do
    vt_block
    |> extract_component_blocks(tag)
    |> Enum.map(fn sub ->
      {props, _} = extract_block_props(sub)
      offset_to = parse_ical_offset(get_prop_raw(props, "TZOFFSETTO") || "+0000")
      offset_from = parse_ical_offset(get_prop_raw(props, "TZOFFSETFROM") || "+0000")
      rrule = parse_rrule_map(get_prop_raw(props, "RRULE"))
      dtstart = parse_naive_ical(get_prop_raw(props, "DTSTART"))

      %{
        kind: kind,
        offset_to: offset_to,
        offset_from: offset_from,
        rrule: rrule,
        dtstart: dtstart
      }
    end)
  end

  defp parse_ical_offset(str) when is_binary(str) do
    trimmed = String.trim(str)

    case Regex.run(~r/^([+-])(\d{2}):?(\d{2})(?::?(\d{2}))?$/, trimmed, capture: :all_but_first) do
      [sign_str, hh, mm | rest] ->
        sign = if sign_str == "-", do: -1, else: 1
        ss = case rest do
          [s] when s != "" -> String.to_integer(s)
          _ -> 0
        end

        sign * (String.to_integer(hh) * 3600 + String.to_integer(mm) * 60 + ss)

      _ ->
        0
    end
  end

  defp parse_ical_offset(_), do: 0

  # --- VEVENT Parsing ---

  defp parse_raw_vevent(block, vtimezones) do
    {props, exdate_props, organizer, attendees} = extract_vevent_all_props(block)

    uid = get_prop_text(props, "UID")
    status = String.upcase(get_prop_text(props, "STATUS") || "")

    if is_nil(uid) or uid == @internal_config_uid or status == "CANCELLED" do
      nil
    else
      dtstart_info = parse_dt_prop(Map.get(props, "DTSTART"), vtimezones)

      if dtstart_info do
        summary = get_prop_text(props, "SUMMARY") || "(No Title)"
        description = get_prop_text(props, "DESCRIPTION") || ""
        location = get_prop_text(props, "LOCATION") || ""
        location_url = sanitize_location_url(get_prop_text(props, "X-UKKO-LOCATION-URL"))
        rrule_str = get_prop_raw(props, "RRULE")
        dtend_info = parse_dt_prop(Map.get(props, "DTEND"), vtimezones)
        duration_sec = parse_duration_seconds(get_prop_raw(props, "DURATION"))
        recurrence_id = parse_dt_prop(Map.get(props, "RECURRENCE-ID"), vtimezones)

        exdates =
          exdate_props
          |> Enum.flat_map(fn {params, val} ->
            val
            |> String.split(",", trim: true)
            |> Enum.map(fn single_val ->
              parse_dt_prop({params, single_val}, vtimezones)
            end)
          end)
          |> Enum.reject(&is_nil/1)
          |> Enum.map(&recurrence_match_key/1)
          |> MapSet.new()

        %{
          uid: uid,
          summary: summary,
          description: description,
          location: location,
          location_url: location_url,
          dtstart: dtstart_info,
          dtend: dtend_info,
          duration_sec: duration_sec,
          rrule: parse_rrule_map(rrule_str),
          rrule_raw: String.trim(rrule_str || ""),
          recurrence_id: recurrence_id,
          exdates: exdates,
          organizer: organizer,
          attendees: Enum.reverse(attendees)
        }
      else
        nil
      end
    end
  end

  defp extract_vevent_all_props(block) do
    block
    |> :binary.split(["\r\n", "\n"], [:global, :trim_all])
    |> Enum.reduce({%{}, [], nil, [], false}, fn line, {props_acc, exdates_acc, org_acc, att_acc, in_alarm} ->
      trimmed_line = String.trim(line)

      cond do
        trimmed_line == "BEGIN:VALARM" ->
          {props_acc, exdates_acc, org_acc, att_acc, true}

        trimmed_line == "END:VALARM" ->
          {props_acc, exdates_acc, org_acc, att_acc, false}

        in_alarm ->
          {props_acc, exdates_acc, org_acc, att_acc, true}

        true ->
          case split_prop_line(line) do
            {key_and_params, value} ->
              [prop_name | params] = String.split(key_and_params, ";")
              key = String.upcase(String.trim(prop_name))

              cond do
                key == "EXDATE" ->
                  {props_acc, [{params, value} | exdates_acc], org_acc, att_acc, false}

                key == "ORGANIZER" and is_nil(org_acc) ->
                  {props_acc, exdates_acc, parse_participant(params, value, false), att_acc, false}

                key == "ATTENDEE" ->
                  case parse_participant(params, value, true) do
                    nil -> {props_acc, exdates_acc, org_acc, att_acc, false}
                    att -> {props_acc, exdates_acc, org_acc, [att | att_acc], false}
                  end

                true ->
                  {Map.put_new(props_acc, key, {params, value}), exdates_acc, org_acc, att_acc, false}
              end

            :error ->
              {props_acc, exdates_acc, org_acc, att_acc, false}
          end
      end
    end)
    |> then(fn {props, exdates, org, atts, _in_alarm} -> {props, exdates, org, atts} end)
  end

  defp extract_block_props(block) do
    {props, exdates, _org, _atts} = extract_vevent_all_props(block)
    {props, exdates}
  end

  defp parse_participant(params, raw_value, is_attendee) do
    email =
      raw_value
      |> String.trim()
      |> String.replace(~r/^mailto:/i, "")
      |> String.trim()

    if email == "" or not String.contains?(email, "@") do
      nil
    else
      param_map =
        Enum.reduce(params, %{}, fn param, acc ->
          case String.split(param, "=", parts: 2) do
            [k, v] ->
              clean_k = String.upcase(String.trim(k))
              clean_v = v |> String.trim() |> String.trim("\"") |> unescape_text()
              Map.put(acc, clean_k, clean_v)

            _ ->
              acc
          end
        end)

      cn = Map.get(param_map, "CN") || ""
      name = if cn == "" or String.downcase(cn) == String.downcase(email), do: "", else: cn

      if is_attendee do
        %{
          name: name,
          email: email,
          status: Map.get(param_map, "PARTSTAT") || "NEEDS-ACTION",
          role: Map.get(param_map, "ROLE") || "REQ-PARTICIPANT"
        }
      else
        %{
          name: name,
          email: email
        }
      end
    end
  end

  defp parse_dt_prop(nil, _vtimezones), do: nil

  defp parse_dt_prop({params, raw_value}, vtimezones) do
    val = String.trim(raw_value)
    tzid = extract_tzid(params)
    has_date_param = Enum.any?(params, fn p -> String.upcase(String.trim(p)) == "VALUE=DATE" end)

    cond do
      has_date_param or match?(<<_::binary-size(8)>>, val) ->
        case parse_date_ical(String.slice(val, 0, 8)) do
          {:ok, date} -> {:date, date}
          _ -> nil
        end

      String.ends_with?(val, "Z") ->
        case parse_naive_ical(String.trim_trailing(val, "Z")) do
          {:ok, ndt} ->
            utc_dt = DateTime.from_naive!(ndt, "Etc/UTC")
            {:utc, utc_dt, ndt, "UTC"}

          _ ->
            nil
        end

      true ->
        case parse_naive_ical(val) do
          {:ok, ndt} ->
            utc_dt = local_ndt_to_utc(ndt, tzid, vtimezones)
            {:local, utc_dt, ndt, tzid}

          _ ->
            nil
        end
    end
  end

  defp recurrence_match_key({:date, %Date{} = d}), do: {:date, Date.to_iso8601(d)}
  defp recurrence_match_key({:utc, %DateTime{} = dt, _ndt, _tz}), do: {:utc_unix, DateTime.to_unix(dt)}
  defp recurrence_match_key({:local, %DateTime{} = dt, _ndt, _tz}), do: {:utc_unix, DateTime.to_unix(dt)}
  defp recurrence_match_key(_), do: :none

  defp dt_info_to_iso({:date, %Date{} = d}), do: Date.to_iso8601(d)
  defp dt_info_to_iso({:utc, %DateTime{} = dt, _ndt, _tz}), do: format_utc_iso(dt)
  defp dt_info_to_iso({:local, %DateTime{} = dt, _ndt, _tz}), do: format_utc_iso(dt)
  defp dt_info_to_iso(_), do: nil

  defp extract_tzid(params) when is_list(params) do
    Enum.find_value(params, fn param ->
      case String.split(param, "=", parts: 2) do
        [k, v] ->
          if String.upcase(String.trim(k)) == "TZID", do: clean_tzid(v), else: nil

        _ ->
          nil
      end
    end)
  end

  defp clean_tzid(nil), do: nil

  defp clean_tzid(str) when is_binary(str) do
    str
    |> String.trim()
    |> String.trim("\"")
    |> String.trim()
  end

  defp local_ndt_to_utc(%NaiveDateTime{} = ndt, tzid, vtimezones) do
    offset_sec = resolve_tz_offset_seconds(tzid, ndt, vtimezones)

    ndt
    |> NaiveDateTime.add(-offset_sec, :second)
    |> DateTime.from_naive!("Etc/UTC")
  end

  @doc """
  Resolves the UTC offset in seconds (e.g. `-28800` for `GMT-08:00` / PST) for a given `tzid`
  and local `NaiveDateTime`, using direct GMT/UTC offset strings, `VTIMEZONE` rules, or
  standard IANA/Windows timezone rules.
  """
  def resolve_tz_offset_seconds(tzid, %NaiveDateTime{} = ndt, vtimezones \\ %{}) do
    cleaned = clean_tzid(tzid)

    cond do
      is_nil(cleaned) or cleaned == "" ->
        # Floating local time: default to America/Los_Angeles (Pacific Time)
        us_dst_offset(ndt, -8 * 3600, -7 * 3600)

      offset = parse_direct_gmt_tzid(cleaned) ->
        offset

      Map.has_key?(vtimezones, cleaned) ->
        resolve_vtimezone_offset(Map.get(vtimezones, cleaned), ndt)

      true ->
        known_timezone_offset(cleaned, ndt)
    end
  end

  defp parse_direct_gmt_tzid(tzid) do
    cond do
      String.upcase(tzid) in ["UTC", "GMT", "ETC/UTC", "ETC/GMT", "Z"] ->
        0

      # POSIX Etc/GMT+8 means 8 hours behind UTC (-08:00)
      match = Regex.run(~r/^Etc\/GMT([+-])(\d{1,2})$/i, tzid, capture: :all_but_first) ->
        [sign_str, hh] = match
        sign = if sign_str == "+", do: -1, else: 1
        sign * String.to_integer(hh) * 3600

      # Standard GMT-08:00, UTC-08:00, GMT-8, -08:00, -0800
      match =
          Regex.run(~r/^(?:GMT|UTC)?([+-])(\d{1,2})(?::?(\d{2}))?$/i, tzid,
            capture: :all_but_first
          ) ->
        case match do
          [sign_str, hh] ->
            sign = if sign_str == "-", do: -1, else: 1
            sign * String.to_integer(hh) * 3600

          [sign_str, hh, mm] ->
            sign = if sign_str == "-", do: -1, else: 1
            m_val = if mm == "", do: 0, else: String.to_integer(mm)
            sign * (String.to_integer(hh) * 3600 + m_val * 60)
        end

      true ->
        nil
    end
  end

  defp resolve_vtimezone_offset(%{standard: std_rules, daylight: dst_rules}, %NaiveDateTime{} = ndt) do
    active_std = pick_active_tz_rule(std_rules, ndt.year)
    active_dst = pick_active_tz_rule(dst_rules, ndt.year)

    cond do
      active_std && active_dst ->
        dst_start = tz_rule_transition_ndt(active_dst, ndt.year, {3, 7, 2})
        std_start = tz_rule_transition_ndt(active_std, ndt.year, {11, 7, 1})

        if NaiveDateTime.compare(dst_start, std_start) == :lt do
          if NaiveDateTime.compare(ndt, dst_start) in [:gt, :eq] and
               NaiveDateTime.compare(ndt, std_start) == :lt do
            active_dst.offset_to
          else
            active_std.offset_to
          end
        else
          # Southern hemisphere
          if NaiveDateTime.compare(ndt, std_start) in [:gt, :eq] and
               NaiveDateTime.compare(ndt, dst_start) == :lt do
            active_std.offset_to
          else
            active_dst.offset_to
          end
        end

      active_std ->
        active_std.offset_to

      active_dst ->
        active_dst.offset_to

      true ->
        us_dst_offset(ndt, -8 * 3600, -7 * 3600)
    end
  end

  defp pick_active_tz_rule([], _year), do: nil

  defp pick_active_tz_rule(rules, year) do
    valid =
      Enum.filter(rules, fn r ->
        case parse_until_date(Map.get(r.rrule, "UNTIL")) do
          nil -> true
          %Date{year: until_year} -> until_year >= year
        end
      end)

    List.last(valid) || List.last(rules)
  end

  defp tz_rule_transition_ndt(rule, year, {default_month, default_wday, default_nth}) do
    month = parse_int(Map.get(rule.rrule, "BYMONTH"), default_month)

    {wday, nth} =
      case parse_byday_token(Map.get(rule.rrule, "BYDAY")) do
        {n, wd} when not is_nil(n) -> {wd, n}
        _ -> {default_wday, default_nth}
      end

    date = nth_weekday_of_month(year, month, wday, nth)

    time =
      case rule.dtstart do
        {:ok, %NaiveDateTime{} = dt} -> NaiveDateTime.to_time(dt)
        _ -> ~T[02:00:00]
      end

    NaiveDateTime.new!(date, time)
  end

  defp known_timezone_offset(tzid, %NaiveDateTime{} = ndt) do
    up = String.upcase(tzid)

    cond do
      up in [
        "AMERICA/LOS_ANGELES",
        "AMERICA/VANCOUVER",
        "AMERICA/TIJUANA",
        "US/PACIFIC",
        "CANADA/PACIFIC",
        "PACIFIC STANDARD TIME",
        "PST8PDT"
      ] ->
        us_dst_offset(ndt, -8 * 3600, -7 * 3600)

      up in ["AMERICA/PHOENIX", "US/ARIZONA", "US MOUNTAIN STANDARD TIME"] ->
        -7 * 3600

      up in [
        "AMERICA/DENVER",
        "AMERICA/EDMONTON",
        "AMERICA/BOISE",
        "US/MOUNTAIN",
        "MOUNTAIN STANDARD TIME",
        "MST7MDT"
      ] ->
        us_dst_offset(ndt, -7 * 3600, -6 * 3600)

      up in [
        "AMERICA/CHICAGO",
        "AMERICA/WINNIPEG",
        "US/CENTRAL",
        "CENTRAL STANDARD TIME",
        "CST6CDT"
      ] ->
        us_dst_offset(ndt, -6 * 3600, -5 * 3600)

      up in [
        "AMERICA/NEW_YORK",
        "AMERICA/TORONTO",
        "AMERICA/DETROIT",
        "US/EASTERN",
        "EASTERN STANDARD TIME",
        "EST5EDT"
      ] ->
        us_dst_offset(ndt, -5 * 3600, -4 * 3600)

      up in ["AMERICA/ANCHORAGE", "US/ALASKA", "ALASKAN STANDARD TIME"] ->
        us_dst_offset(ndt, -9 * 3600, -8 * 3600)

      up in ["PACIFIC/HONOLULU", "US/HAWAII", "HAWAIIAN STANDARD TIME"] ->
        -10 * 3600

      up in ["EUROPE/LONDON", "EUROPE/DUBLIN", "EUROPE/LISBON", "GMT STANDARD TIME"] ->
        eu_dst_offset(ndt, 0, 3600)

      up in [
        "EUROPE/PARIS",
        "EUROPE/BERLIN",
        "EUROPE/ROME",
        "EUROPE/MADRID",
        "EUROPE/AMSTERDAM",
        "EUROPE/ZURICH",
        "EUROPE/STOCKHOLM",
        "W. EUROPE STANDARD TIME",
        "CENTRAL EUROPEAN STANDARD TIME"
      ] ->
        eu_dst_offset(ndt, 3600, 2 * 3600)

      up in ["EUROPE/HELSINKI", "EUROPE/ATHENS", "EUROPE/KYIV", "E. EUROPE STANDARD TIME"] ->
        eu_dst_offset(ndt, 2 * 3600, 3 * 3600)

      up in ["ASIA/TOKYO", "TOKYO STANDARD TIME"] ->
        9 * 3600

      up in ["ASIA/SHANGHAI", "ASIA/HONG_KONG", "ASIA/SINGAPORE", "ASIA/TAIPEI"] ->
        8 * 3600

      up in ["ASIA/KOLKATA", "ASIA/CALCUTTA", "INDIA STANDARD TIME"] ->
        5 * 3600 + 1800

      true ->
        # Fallback to Pacific Time
        us_dst_offset(ndt, -8 * 3600, -7 * 3600)
    end
  end

  defp us_dst_offset(%NaiveDateTime{} = ndt, std_offset, dst_offset) do
    dst_start = NaiveDateTime.new!(nth_weekday_of_month(ndt.year, 3, 7, 2), ~T[02:00:00])
    std_start = NaiveDateTime.new!(nth_weekday_of_month(ndt.year, 11, 7, 1), ~T[02:00:00])

    if NaiveDateTime.compare(ndt, dst_start) in [:gt, :eq] and
         NaiveDateTime.compare(ndt, std_start) == :lt do
      dst_offset
    else
      std_offset
    end
  end

  defp eu_dst_offset(%NaiveDateTime{} = ndt, std_offset, dst_offset) do
    dst_start = NaiveDateTime.new!(nth_weekday_of_month(ndt.year, 3, 7, -1), ~T[01:00:00])
    std_start = NaiveDateTime.new!(nth_weekday_of_month(ndt.year, 10, 7, -1), ~T[01:00:00])

    if NaiveDateTime.compare(ndt, dst_start) in [:gt, :eq] and
         NaiveDateTime.compare(ndt, std_start) == :lt do
      dst_offset
    else
      std_offset
    end
  end

  # Computes the nth weekday (1=Monday .. 7=Sunday) of a given year and month.
  # Positive `nth` counts from the start of the month (1 = 1st, 2 = 2nd);
  # negative `nth` counts from the end of the month (-1 = last).
  defp nth_weekday_of_month(year, month, target_wday, nth) when nth > 0 do
    first = Date.new!(year, month, 1)
    first_wday = Date.day_of_week(first)
    diff = rem(target_wday - first_wday + 7, 7)
    day = 1 + diff + (nth - 1) * 7
    days_in_m = Calendar.ISO.days_in_month(year, month)
    Date.new!(year, month, min(day, days_in_m))
  end

  defp nth_weekday_of_month(year, month, target_wday, nth) when nth < 0 do
    days_in_m = Calendar.ISO.days_in_month(year, month)
    last = Date.new!(year, month, days_in_m)
    last_wday = Date.day_of_week(last)
    diff = rem(last_wday - target_wday + 7, 7)
    day = days_in_m - diff + (nth + 1) * 7
    Date.new!(year, month, max(day, 1))
  end

  # --- Recurrence (RRULE) Expansion & Event Formatting ---

  defp expand_vevent(ev, vtimezones, range_start_dt, range_end_dt, override_keys, extra_meta) do
    if map_size(ev.rrule) > 0 and is_nil(ev.recurrence_id) do
      excluded = MapSet.union(ev.exdates, override_keys)
      expand_recurring_vevent(ev, vtimezones, range_start_dt, range_end_dt, excluded, extra_meta)
    else
      [build_single_event_map(ev, extra_meta)]
    end
  end

  defp build_single_event_map(ev, extra_meta) do
    {all_day, start_str, end_str} =
      case {ev.dtstart, ev.dtend} do
        {{:date, %Date{} = s_date}, {:date, %Date{} = e_date}} ->
          norm_end =
            if Date.compare(e_date, s_date) in [:lt, :eq],
              do: Date.add(s_date, 1),
              else: e_date

          {true, Date.to_iso8601(s_date), Date.to_iso8601(norm_end)}

        {{:date, %Date{} = s_date}, _} ->
          {true, Date.to_iso8601(s_date), Date.to_iso8601(Date.add(s_date, 1))}

        {{_, %DateTime{} = s_utc, _, _}, {_, %DateTime{} = e_utc, _, _}} ->
          {false, format_utc_iso(s_utc), format_utc_iso(e_utc)}

        {{_, %DateTime{} = s_utc, _, _}, nil} ->
          dur = ev.duration_sec || 3600
          e_utc = DateTime.add(s_utc, dur, :second)
          {false, format_utc_iso(s_utc), format_utc_iso(e_utc)}
      end

    decorate_event_map(ev, start_str, end_str, all_day, extra_meta)
  end

  defp expand_recurring_vevent(ev, vtimezones, range_start_dt, range_end_dt, excluded, extra_meta) do
    win_start_date =
      case range_start_dt do
        %DateTime{} = dt -> Date.add(DateTime.to_date(dt), -2)
        _ -> Date.add(Date.utc_today(), -60)
      end

    win_end_date =
      case range_end_dt do
        %DateTime{} = dt -> Date.add(DateTime.to_date(dt), 2)
        _ -> Date.add(Date.utc_today(), 366)
      end

    start_date = extract_local_date(ev.dtstart)
    until_utc = parse_until_utc(Map.get(ev.rrule, "UNTIL"))
    occurrence_dates = generate_rrule_dates(ev.rrule, start_date, win_start_date, win_end_date, excluded)

    occurrence_dates
    |> Enum.map(fn occ_date ->
      case ev.dtstart do
        {:date, %Date{} = orig_s} ->
          if not is_nil(until_utc) and Date.compare(occ_date, DateTime.to_date(until_utc)) == :gt do
            nil
          else
            day_span =
              case ev.dtend do
                {:date, %Date{} = orig_e} -> max(Date.diff(orig_e, orig_s), 1)
                _ -> 1
              end

            s_iso = Date.to_iso8601(occ_date)
            e_iso = Date.to_iso8601(Date.add(occ_date, day_span))
            decorate_event_map(ev, s_iso, e_iso, true, extra_meta)
          end

        {kind, %DateTime{} = orig_s_utc, %NaiveDateTime{} = orig_s_ndt, tzid} ->
          duration_sec =
            case ev.dtend do
              {_, %DateTime{} = orig_e_utc, _, _} ->
                max(DateTime.diff(orig_e_utc, orig_s_utc, :second), 0)

              _ ->
                ev.duration_sec || 3600
            end

          occ_ndt = NaiveDateTime.new!(occ_date, NaiveDateTime.to_time(orig_s_ndt))

          occ_s_utc =
            if kind == :utc do
              DateTime.from_naive!(occ_ndt, "Etc/UTC")
            else
              local_ndt_to_utc(occ_ndt, tzid, vtimezones)
            end

          cond do
            MapSet.member?(excluded, {:utc_unix, DateTime.to_unix(occ_s_utc)}) ->
              nil

            not is_nil(until_utc) and DateTime.compare(occ_s_utc, until_utc) == :gt ->
              nil

            true ->
              occ_e_utc = DateTime.add(occ_s_utc, duration_sec, :second)
              decorate_event_map(ev, format_utc_iso(occ_s_utc), format_utc_iso(occ_e_utc), false, extra_meta)
          end
      end
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp generate_rrule_dates(rrule, %Date{} = start_date, win_start, win_end, excluded) do
    freq = String.upcase(Map.get(rrule, "FREQ", ""))
    interval = max(parse_int(Map.get(rrule, "INTERVAL"), 1), 1)
    max_count = parse_int(Map.get(rrule, "COUNT"), nil)
    raw_until = Map.get(rrule, "UNTIL")
    until_utc = parse_until_utc(raw_until)

    until_date =
      cond do
        not is_nil(until_utc) ->
          # Add 1-day cushion for date generation; exact UTC cutoff is enforced per occurrence
          Date.add(DateTime.to_date(until_utc), 1)

        true ->
          parse_until_date(raw_until)
      end

    eff_end =
      if until_date && Date.compare(until_date, win_end) == :lt do
        until_date
      else
        win_end
      end

    if Date.compare(start_date, eff_end) == :gt or Date.compare(eff_end, win_start) == :lt do
      []
    else
      has_count = is_integer(max_count) and max_count > 0

      raw_dates =
        case freq do
          "DAILY" ->
            generate_daily_dates(start_date, win_start, eff_end, interval, has_count)

          "WEEKLY" ->
            generate_weekly_dates(
              start_date,
              win_start,
              eff_end,
              interval,
              Map.get(rrule, "BYDAY"),
              has_count
            )

          "MONTHLY" ->
            generate_monthly_dates(start_date, eff_end, interval, rrule)

          "YEARLY" ->
            generate_yearly_dates(start_date, eff_end, interval, rrule)

          _ ->
            [start_date]
        end

      counted_dates =
        if has_count do
          Enum.take(raw_dates, max_count)
        else
          raw_dates
        end

      Enum.filter(counted_dates, fn d ->
        Date.compare(d, win_start) in [:gt, :eq] and
          Date.compare(d, eff_end) in [:lt, :eq] and
          not MapSet.member?(excluded, {:date, Date.to_iso8601(d)})
      end)
    end
  end

  defp generate_daily_dates(start_date, win_start, eff_end, interval, has_count) do
    start_idx =
      if not has_count and Date.compare(start_date, win_start) == :lt do
        max(0, div(Date.diff(win_start, start_date), interval) - 1)
      else
        0
      end

    Stream.iterate(start_idx, &(&1 + 1))
    |> Stream.take(2000)
    |> Stream.map(fn i -> Date.add(start_date, i * interval) end)
    |> Enum.take_while(fn d -> Date.compare(d, eff_end) in [:lt, :eq] end)
  end

  defp generate_weekly_dates(start_date, win_start, eff_end, interval, byday_str, has_count) do
    weekdays =
      case byday_str do
        nil ->
          [Date.day_of_week(start_date)]

        str ->
          str
          |> String.split(",", trim: true)
          |> Enum.map(&parse_byday_token/1)
          |> Enum.map(fn {_nth, wd} -> wd end)
          |> Enum.reject(&is_nil/1)
          |> Enum.uniq()
          |> Enum.sort()
      end

    weekdays = if weekdays == [], do: [Date.day_of_week(start_date)], else: weekdays
    start_monday = Date.add(start_date, -(Date.day_of_week(start_date) - 1))

    start_week_idx =
      if not has_count and Date.compare(start_monday, win_start) == :lt do
        max(0, div(Date.diff(win_start, start_monday), interval * 7) - 1)
      else
        0
      end

    Stream.iterate(start_week_idx, &(&1 + 1))
    |> Stream.take(1000)
    |> Stream.flat_map(fn w ->
      week_monday = Date.add(start_monday, w * interval * 7)
      Enum.map(weekdays, fn wd -> Date.add(week_monday, wd - 1) end)
    end)
    |> Stream.filter(fn d -> Date.compare(d, start_date) in [:gt, :eq] end)
    |> Enum.take_while(fn d -> Date.compare(d, eff_end) in [:lt, :eq] end)
  end

  defp generate_monthly_dates(start_date, eff_end, interval, rrule) do
    byday_token = parse_byday_token(Map.get(rrule, "BYDAY"))
    target_mday = parse_int(Map.get(rrule, "BYMONTHDAY"), start_date.day)

    Stream.iterate(0, &(&1 + 1))
    |> Stream.take(600)
    |> Stream.map(fn i ->
      total_months = start_date.year * 12 + (start_date.month - 1) + i * interval
      year = div(total_months, 12)
      month = rem(total_months, 12) + 1

      case byday_token do
        {nth, wd} when not is_nil(nth) and not is_nil(wd) ->
          nth_weekday_of_month(year, month, wd, nth)

        _ ->
          days_in_m = Calendar.ISO.days_in_month(year, month)

          if target_mday >= 1 and target_mday <= days_in_m do
            Date.new!(year, month, target_mday)
          else
            nil
          end
      end
    end)
    |> Stream.reject(&is_nil/1)
    |> Stream.filter(fn d -> Date.compare(d, start_date) in [:gt, :eq] end)
    |> Enum.take_while(fn d -> Date.compare(d, eff_end) in [:lt, :eq] end)
  end

  defp generate_yearly_dates(start_date, eff_end, interval, rrule) do
    target_month = parse_int(Map.get(rrule, "BYMONTH"), start_date.month)
    byday_token = parse_byday_token(Map.get(rrule, "BYDAY"))

    Stream.iterate(0, &(&1 + 1))
    |> Stream.take(200)
    |> Stream.map(fn i ->
      year = start_date.year + i * interval

      case byday_token do
        {nth, wd} when not is_nil(nth) and not is_nil(wd) ->
          nth_weekday_of_month(year, target_month, wd, nth)

        _ ->
          days_in_m = Calendar.ISO.days_in_month(year, target_month)
          Date.new!(year, target_month, min(start_date.day, days_in_m))
      end
    end)
    |> Stream.filter(fn d -> Date.compare(d, start_date) in [:gt, :eq] end)
    |> Enum.take_while(fn d -> Date.compare(d, eff_end) in [:lt, :eq] end)
  end

  defp decorate_event_map(ev, start_str, end_str, all_day, extra_meta) do
    color = Map.get(extra_meta, :color) || Map.get(extra_meta, "color")
    calendar_name = Map.get(extra_meta, :calendar_name) || Map.get(extra_meta, "calendar_name") || "Ukko Calendar"
    sub_id = Map.get(extra_meta, :subscription_id) || Map.get(extra_meta, "subscription_id")
    read_only = Map.get(extra_meta, :read_only, false)

    id_prefix = if sub_id, do: "#{sub_id}::#{ev.uid}", else: ev.uid
    series_rrule = Map.get(extra_meta, :series_rrule)
    ev_rrule_raw = Map.get(ev, :rrule_raw, "")
    effective_rrule = if ev_rrule_raw != "", do: ev_rrule_raw, else: series_rrule || ""

    is_recurring =
      map_size(ev.rrule) > 0 or not is_nil(ev.recurrence_id) or
        (is_binary(series_rrule) and series_rrule != "")

    rec_id_str =
      cond do
        not is_nil(ev.recurrence_id) -> dt_info_to_iso(ev.recurrence_id)
        is_recurring -> start_str
        true -> nil
      end

    base = %{
      id: "#{id_prefix}::#{start_str}",
      uid: ev.uid,
      title: ev.summary,
      start: start_str,
      end: end_str,
      allDay: all_day,
      description: ev.description,
      location: ev.location,
      locationUrl: Map.get(ev, :location_url),
      organizer: Map.get(ev, :organizer),
      attendees: Map.get(ev, :attendees, []),
      isRecurring: is_recurring,
      rrule: effective_rrule,
      recurrenceId: rec_id_str,
      readOnly: read_only,
      calendarName: calendar_name,
      subscriptionId: sub_id,
      extendedProps: %{
        uid: ev.uid,
        description: ev.description,
        location: ev.location,
        locationUrl: Map.get(ev, :location_url),
        organizer: Map.get(ev, :organizer),
        attendees: Map.get(ev, :attendees, []),
        isRecurring: is_recurring,
        rrule: effective_rrule,
        recurrenceId: rec_id_str,
        readOnly: read_only,
        calendarName: calendar_name,
        subscriptionId: sub_id,
        color: color
      }
    }

    if color do
      Map.merge(base, %{backgroundColor: color, color: color})
    else
      base
    end
  end

  defp filter_by_range(events, nil, nil), do: events

  defp filter_by_range(events, range_start_dt, range_end_dt) do
    Enum.filter(events, fn ev ->
      ev_start = parse_event_bound_utc(ev.start, false)
      ev_end = parse_event_bound_utc(ev.end, true) || ev_start

      after_start =
        case {range_start_dt, ev_end} do
          {%DateTime{} = rs, %DateTime{} = ee} -> DateTime.compare(ee, rs) == :gt
          _ -> true
        end

      before_end =
        case {range_end_dt, ev_start} do
          {%DateTime{} = re, %DateTime{} = es} -> DateTime.compare(es, re) == :lt
          _ -> true
        end

      after_start and before_end
    end)
  end

  defp parse_event_bound_utc(str, is_end) when is_binary(str) do
    cond do
      String.length(str) == 10 ->
        case Date.from_iso8601(str) do
          {:ok, d} ->
            # Give all-day events a +/- 14h timezone cushion so local day boundaries match
            base = DateTime.new!(d, ~T[00:00:00], "Etc/UTC")
            if is_end, do: DateTime.add(base, 14 * 3600, :second), else: DateTime.add(base, -14 * 3600, :second)

          _ ->
            nil
        end

      match?({:ok, _, _}, DateTime.from_iso8601(str)) ->
        {:ok, dt, _} = DateTime.from_iso8601(str)
        dt

      true ->
        nil
    end
  end

  defp parse_filter_range(start_iso, end_iso) do
    {parse_iso_dt(start_iso), parse_iso_dt(end_iso)}
  end

  defp parse_iso_dt(nil), do: nil

  defp parse_iso_dt(iso) when is_binary(iso) do
    trimmed = String.trim(iso)

    cond do
      match?({:ok, _, _}, DateTime.from_iso8601(trimmed)) ->
        {:ok, dt, _} = DateTime.from_iso8601(trimmed)
        DateTime.shift_zone!(dt, "Etc/UTC")

      match?({:ok, _}, NaiveDateTime.from_iso8601(trimmed)) ->
        {:ok, ndt} = NaiveDateTime.from_iso8601(trimmed)
        DateTime.from_naive!(ndt, "Etc/UTC")

      match?({:ok, _}, NaiveDateTime.from_iso8601(trimmed <> ":00")) ->
        {:ok, ndt} = NaiveDateTime.from_iso8601(trimmed <> ":00")
        DateTime.from_naive!(ndt, "Etc/UTC")

      match?({:ok, _}, Date.from_iso8601(trimmed)) ->
        {:ok, d} = Date.from_iso8601(trimmed)
        DateTime.new!(d, ~T[00:00:00], "Etc/UTC")

      true ->
        nil
    end
  end

  defp extract_local_date({:date, %Date{} = d}), do: d
  defp extract_local_date({_, _, %NaiveDateTime{} = ndt, _}), do: NaiveDateTime.to_date(ndt)

  defp parse_rrule_map(nil), do: %{}

  defp parse_rrule_map(rrule_str) when is_binary(rrule_str) do
    rrule_str
    |> String.trim()
    |> String.split(";", trim: true)
    |> Enum.reduce(%{}, fn part, acc ->
      case String.split(part, "=", parts: 2) do
        [k, v] -> Map.put(acc, String.upcase(String.trim(k)), String.trim(v))
        _ -> acc
      end
    end)
  end

  defp parse_byday_token(nil), do: nil

  defp parse_byday_token(str) when is_binary(str) do
    first = str |> String.split(",", trim: true) |> List.first() || ""

    case Regex.run(~r/^([+-]?\d+)?(MO|TU|WE|TH|FR|SA|SU)$/i, String.trim(first),
           capture: :all_but_first
         ) do
      [nth_str, wd_str] ->
        nth = if nth_str == "", do: nil, else: String.to_integer(nth_str)
        {nth, weekday_number(String.upcase(wd_str))}

      _ ->
        nil
    end
  end

  defp weekday_number("MO"), do: 1
  defp weekday_number("TU"), do: 2
  defp weekday_number("WE"), do: 3
  defp weekday_number("TH"), do: 4
  defp weekday_number("FR"), do: 5
  defp weekday_number("SA"), do: 6
  defp weekday_number("SU"), do: 7
  defp weekday_number(_), do: nil

  defp weekday_code(1), do: "MO"
  defp weekday_code(2), do: "TU"
  defp weekday_code(3), do: "WE"
  defp weekday_code(4), do: "TH"
  defp weekday_code(5), do: "FR"
  defp weekday_code(6), do: "SA"
  defp weekday_code(7), do: "SU"

  defp parse_until_date(nil), do: nil

  defp parse_until_date(str) when is_binary(str) do
    case parse_date_ical(String.slice(String.trim(str), 0, 8)) do
      {:ok, d} -> d
      _ -> nil
    end
  end

  defp parse_until_utc(nil), do: nil

  defp parse_until_utc(str) when is_binary(str) do
    trimmed = String.trim(str)

    if String.contains?(trimmed, "T") do
      clean = String.trim_trailing(trimmed, "Z")

      case parse_naive_ical(clean) do
        {:ok, ndt} -> DateTime.from_naive!(ndt, "Etc/UTC")
        _ -> nil
      end
    else
      nil
    end
  end

  defp parse_duration_seconds(nil), do: nil

  defp parse_duration_seconds(str) when is_binary(str) do
    trimmed = String.trim(str)

    case Regex.run(
           ~r/^([+-])?P(?:(\d+)W)?(?:(\d+)D)?(?:T(?:(\d+)H)?(?:(\d+)M)?(?:(\d+)S)?)?$/i,
           trimmed,
           capture: :all_but_first
         ) do
      [_sign | parts] ->
        [w, d, h, m, s] =
          Enum.map(parts, fn
            "" -> 0
            nil -> 0
            n -> String.to_integer(n)
          end)

        w * 604_800 + d * 86_400 + h * 3600 + m * 60 + s

      _ ->
        nil
    end
  end

  defp parse_int(nil, default), do: default

  defp parse_int(str, default) when is_binary(str) do
    case Integer.parse(String.trim(str)) do
      {n, ""} -> n
      _ -> default
    end
  end

  defp parse_date_ical(<<y::binary-size(4), m::binary-size(2), d::binary-size(2)>>) do
    Date.new(String.to_integer(y), String.to_integer(m), String.to_integer(d))
  rescue
    _ -> :error
  end

  defp parse_date_ical(_), do: :error

  defp parse_naive_ical(
         <<y::binary-size(4), m::binary-size(2), d::binary-size(2), "T", hh::binary-size(2),
           mm::binary-size(2), ss::binary-size(2)>>
       ) do
    NaiveDateTime.new(
      String.to_integer(y),
      String.to_integer(m),
      String.to_integer(d),
      String.to_integer(hh),
      String.to_integer(mm),
      String.to_integer(ss)
    )
  rescue
    _ -> :error
  end

  defp parse_naive_ical(_), do: :error

  defp format_utc_iso(%DateTime{} = dt) do
    Calendar.strftime(dt, "%Y-%m-%dT%H:%M:%SZ")
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

  defp get_prop_raw(props, key) do
    case Map.get(props, key) do
      {_params, value} -> String.trim(value)
      nil -> nil
    end
  end

  defp get_prop_text(props, key) do
    case Map.get(props, key) do
      {_params, value} -> unescape_text(value)
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
  Builds an RFC 5545 `.ics` VCALENDAR string for a single event (or recurring master event).
  Supports optional `:rrule`, `:timezone`, `:recurrence_id_line`, `:sequence`, `:attendees`,
  `:organizer_email`, and `:organizer_name`.
  """
  def build_ics(%{uid: _uid, title: _title, start: start_iso, end: _end_iso} = attrs) do
    tz_tuple =
      if all_day_iso?(start_iso) do
        nil
      else
        supported_vtimezone(Map.get(attrs, :timezone))
      end

    effective_attrs =
      case tz_tuple do
        {canonical_tzid, _vt_block} -> Map.put(attrs, :timezone, canonical_tzid)
        nil -> Map.delete(attrs, :timezone)
      end

    vevent = build_vevent_component(effective_attrs)

    vt_blocks =
      case tz_tuple do
        {_canonical_tzid, vt_block} -> [vt_block]
        nil -> []
      end

    wrap_vcalendar(vt_blocks, [vevent])
  end

  @doc """
  Builds a single `BEGIN:VEVENT ... END:VEVENT` component string from `attrs`.
  """
  def build_vevent_component(%{uid: uid, title: title, start: start_iso, end: end_iso} = attrs) do
    description = Map.get(attrs, :description) || ""
    location = Map.get(attrs, :location) || ""
    location_url = Map.get(attrs, :location_url)
    rrule = sanitize_rrule(Map.get(attrs, :rrule))
    rec_id_line = Map.get(attrs, :recurrence_id_line)
    raw_seq = Map.get(attrs, :sequence)
    sequence = if is_integer(raw_seq) and raw_seq >= 0, do: raw_seq, else: 0
    tzid = non_empty_trimmed(Map.get(attrs, :timezone))
    vtimezones = Map.get(attrs, :vtimezones) || %{}
    attendees = normalize_attendees(Map.get(attrs, :attendees) || [])

    organizer_email =
      Map.get(attrs, :organizer_email) ||
        Application.get_env(:ukko, :thundermail_user) ||
        ""

    organizer_name = Map.get(attrs, :organizer_name) || ""

    dtstamp = iso8601_to_ical_utc(DateTime.utc_now())
    dtstart = format_dt_prop("DTSTART", start_iso, tzid, vtimezones)
    dtend = format_dt_prop("DTEND", end_iso || start_iso, tzid, vtimezones)

    rec_id_lines =
      if is_binary(rec_id_line) and String.trim(rec_id_line) != "" do
        [String.trim(rec_id_line)]
      else
        []
      end

    rrule_lines =
      if is_binary(rrule) and rrule != "" and rec_id_lines == [] do
        ["RRULE:#{rrule}"]
      else
        []
      end

    sequence_lines = ["SEQUENCE:#{sequence}"]

    clean_loc_url = sanitize_location_url(location_url)

    location_url_lines =
      if is_binary(clean_loc_url) and clean_loc_url != "" do
        ["X-UKKO-LOCATION-URL;VALUE=URI:#{clean_loc_url}"]
      else
        []
      end

    participant_lines = build_participant_lines(organizer_email, organizer_name, attendees)

    lines =
      [
        "BEGIN:VEVENT",
        "UID:#{uid}",
        "DTSTAMP:#{dtstamp}"
      ] ++
        rec_id_lines ++
        sequence_lines ++
        [
          dtstart,
          dtend
        ] ++
        rrule_lines ++
        [
          "SUMMARY:#{escape_text(title || "Untitled Event")}",
          "DESCRIPTION:#{escape_text(description)}",
          "LOCATION:#{escape_text(location)}"
        ] ++
        location_url_lines ++
        participant_lines ++
        [
          "END:VEVENT"
        ]

    Enum.join(lines, "\r\n")
  end

  @doc """
  Resets all non-organizer invitees' participation statuses to `"NEEDS-ACTION"` (Pending)
  so invitees show as pending until they accept updated event details.
  """
  def reset_attendees_to_pending(attendees, organizer_email \\ nil) when is_list(attendees) do
    org_down =
      organizer_email
      |> to_string()
      |> String.trim()
      |> String.replace(~r/^mailto:/i, "")
      |> String.downcase()

    attendees
    |> normalize_attendees()
    |> Enum.map(fn att ->
      if org_down != "" and String.downcase(att.email) == org_down do
        %{att | status: "ACCEPTED"}
      else
        %{att | status: "NEEDS-ACTION"}
      end
    end)
  end

  @doc """
  Builds an updated `.ics` payload for an existing non-recurring event, incrementing
  `SEQUENCE` and resetting invitees to `"NEEDS-ACTION"` (Pending) whenever event details change.
  Returns `{updated_ics, final_attendees}`.
  """
  def prepare_single_event_update(raw_ics, new_attrs)
      when is_binary(raw_ics) and is_map(new_attrs) do
    unfolded = unfold(raw_ics)
    vtimezones = parse_vtimezones(unfolded)

    existing_vt_blocks =
      unfolded
      |> extract_component_blocks("VTIMEZONE")
      |> Enum.map(fn inner -> "BEGIN:VTIMEZONE\r\n" <> String.trim(inner) <> "\r\nEND:VTIMEZONE" end)

    vevent_inners =
      unfolded
      |> extract_component_blocks("VEVENT")
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    case vevent_inners do
      [first_inner | _] ->
        existing_ev = parse_raw_vevent(first_inner, vtimezones)
        {existing_props, _, _, _} = extract_vevent_all_props(first_inner)
        next_seq = (parse_int(get_prop_raw(existing_props, "SEQUENCE"), 0) || 0) + 1

        {org_email, org_name} = resolve_organizer_meta(existing_ev, new_attrs)

        final_attendees =
          if single_event_details_changed?(existing_ev, new_attrs) do
            reset_attendees_to_pending(Map.get(new_attrs, :attendees) || [], org_email)
          else
            normalize_attendees(Map.get(new_attrs, :attendees) || [])
          end

        existing_tzid = if existing_ev, do: extract_dtstart_tzid(existing_ev.dtstart), else: nil
        effective_tzid = choose_effective_tzid(Map.get(new_attrs, :timezone), existing_tzid, new_attrs.start)
        vt_blocks = ensure_vtimezone_blocks(existing_vt_blocks, effective_tzid)

        vevent =
          build_vevent_component(
            new_attrs
            |> Map.put(:sequence, next_seq)
            |> Map.put(:attendees, final_attendees)
            |> Map.put(:organizer_email, org_email)
            |> Map.put(:organizer_name, org_name)
            |> Map.put(:timezone, effective_tzid)
            |> Map.put(:vtimezones, vtimezones)
          )

        {wrap_vcalendar(vt_blocks, [vevent]), final_attendees}

      [] ->
        final_attendees =
          reset_attendees_to_pending(
            Map.get(new_attrs, :attendees) || [],
            Map.get(new_attrs, :organizer_email) || Application.get_env(:ukko, :thundermail_user)
          )

        attrs_with_pending = Map.put(new_attrs, :attendees, final_attendees)
        {build_ics(attrs_with_pending), final_attendees}
    end
  end

  @doc """
  Applies a recurring event modification (`"single"` or `"following"`) to an existing
  CalDAV `.ics` payload:
  - `"single"`: Adds/replaces a `RECURRENCE-ID` override `VEVENT` inside the existing `.ics`
    while leaving the master `RRULE` and other occurrences untouched.
    Returns `{:single_put, updated_ics, final_attendees}`.
  - `"following"`:
    - If editing from the very first occurrence of the series, updates the master series in-place
      and returns `{:single_put, updated_ics, final_attendees}`.
    - Otherwise, truncates the original master `RRULE` with `UNTIL` right before the edited
      occurrence, drops subsequent overrides from the original `.ics`, and creates a new
      recurring series `.ics` starting at the edited occurrence.
      Returns `{:split_put, truncated_master_ics, new_uid, new_series_ics, final_attendees}`.
  """
  def apply_recurring_edit(raw_ics, scope, recurrence_id_iso, new_attrs)
      when is_binary(raw_ics) and scope in ["single", "following"] and is_map(new_attrs) do
    unfolded = unfold(raw_ics)
    vtimezones = parse_vtimezones(unfolded)

    vtimezone_blocks =
      unfolded
      |> extract_component_blocks("VTIMEZONE")
      |> Enum.map(fn inner -> "BEGIN:VTIMEZONE\r\n" <> String.trim(inner) <> "\r\nEND:VTIMEZONE" end)

    vevent_inners =
      unfolded
      |> extract_component_blocks("VEVENT")
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    {master_inner, other_inners} = split_master_and_overrides(vevent_inners)

    case master_inner do
      nil ->
        {updated_ics, final_attendees} = prepare_single_event_update(raw_ics, new_attrs)
        {:single_put, updated_ics, final_attendees}

      master_block ->
        master_ev = parse_raw_vevent(master_block, vtimezones)
        {master_props, _, _, _} = extract_vevent_all_props(master_block)

        if is_nil(master_ev) or map_size(master_ev.rrule) == 0 do
          {updated_ics, final_attendees} = prepare_single_event_update(raw_ics, new_attrs)
          {:single_put, updated_ics, final_attendees}
        else
          target_rec_iso = non_empty_trimmed(recurrence_id_iso) || new_attrs.start
          master_seq = parse_int(get_prop_raw(master_props, "SEQUENCE"), 0) || 0

          matching_override_inner =
            Enum.find(other_inners, fn inner ->
              override_matches_target?(inner, target_rec_iso, vtimezones)
            end)

          matching_override_ev =
            if matching_override_inner,
              do: parse_raw_vevent(matching_override_inner, vtimezones),
              else: nil

          override_seq =
            if matching_override_inner do
              {ov_props, _} = extract_block_props(matching_override_inner)
              parse_int(get_prop_raw(ov_props, "SEQUENCE"), master_seq) || master_seq
            else
              master_seq
            end

          next_seq = max(master_seq, override_seq) + 1
          {org_email, org_name} = resolve_organizer_meta(matching_override_ev || master_ev, new_attrs)

          final_attendees =
            if recurring_occurrence_changed?(
                 master_ev,
                 matching_override_ev,
                 scope,
                 target_rec_iso,
                 new_attrs
               ) do
              reset_attendees_to_pending(Map.get(new_attrs, :attendees) || [], org_email)
            else
              normalize_attendees(Map.get(new_attrs, :attendees) || [])
            end

          master_tzid = extract_dtstart_tzid(master_ev.dtstart)

          case scope do
            "single" ->
              # Keep the override's TZID aligned with the master series when timed
              single_tzid =
                if all_day_iso?(new_attrs.start) do
                  nil
                else
                  master_tzid || choose_effective_tzid(Map.get(new_attrs, :timezone), nil, new_attrs.start)
                end

              vt_blocks = ensure_vtimezone_blocks(vtimezone_blocks, single_tzid)

              rec_id_line =
                build_recurrence_id_line(
                  Map.get(master_props, "DTSTART"),
                  target_rec_iso,
                  vtimezones
                )

              override_vevent =
                build_vevent_component(
                  new_attrs
                  |> Map.put(:uid, master_ev.uid)
                  |> Map.put(:rrule, nil)
                  |> Map.put(:recurrence_id_line, rec_id_line)
                  |> Map.put(:sequence, next_seq)
                  |> Map.put(:attendees, final_attendees)
                  |> Map.put(:organizer_email, org_email)
                  |> Map.put(:organizer_name, org_name)
                  |> Map.put(:timezone, single_tzid)
                  |> Map.put(:vtimezones, vtimezones)
                )

              kept_overrides =
                other_inners
                |> Enum.reject(fn inner ->
                  override_matches_target?(inner, target_rec_iso, vtimezones)
                end)
                |> Enum.map(&("BEGIN:VEVENT\r\n" <> &1 <> "\r\nEND:VEVENT"))

              master_wrapped = "BEGIN:VEVENT\r\n" <> master_block <> "\r\nEND:VEVENT"
              updated_ics = wrap_vcalendar(vt_blocks, [master_wrapped | kept_overrides] ++ [override_vevent])
              {:single_put, updated_ics, final_attendees}

            "following" ->
              is_first = first_occurrence?(master_ev.dtstart, target_rec_iso)

              following_tzid =
                choose_effective_tzid(Map.get(new_attrs, :timezone), master_tzid, new_attrs.start)

              adjusted_rrule =
                adjust_rrule_for_following(
                  master_ev,
                  target_rec_iso,
                  new_attrs,
                  is_first,
                  following_tzid,
                  vtimezones
                )

              vt_blocks_following = ensure_vtimezone_blocks(vtimezone_blocks, following_tzid)

              if is_first do
                updated_master =
                  build_vevent_component(
                    new_attrs
                    |> Map.put(:uid, master_ev.uid)
                    |> Map.put(:rrule, adjusted_rrule)
                    |> Map.put(:sequence, master_seq + 1)
                    |> Map.put(:attendees, final_attendees)
                    |> Map.put(:organizer_email, org_email)
                    |> Map.put(:organizer_name, org_name)
                    |> Map.put(:timezone, following_tzid)
                    |> Map.put(:vtimezones, vtimezones)
                  )

                {:single_put, wrap_vcalendar(vt_blocks_following, [updated_master]), final_attendees}
              else
                until_val = compute_until_before(master_ev.dtstart, target_rec_iso)
                truncated_master_inner = replace_master_rrule_until(master_block, master_ev.rrule_raw, until_val)

                kept_prior_overrides =
                  other_inners
                  |> Enum.filter(fn inner ->
                    override_before_target?(inner, target_rec_iso, vtimezones)
                  end)
                  |> Enum.map(&("BEGIN:VEVENT\r\n" <> &1 <> "\r\nEND:VEVENT"))

                truncated_master_ics =
                  wrap_vcalendar(
                    vtimezone_blocks,
                    ["BEGIN:VEVENT\r\n" <> truncated_master_inner <> "\r\nEND:VEVENT" | kept_prior_overrides]
                  )

                new_uid = generate_uid()

                new_master_vevent =
                  build_vevent_component(
                    new_attrs
                    |> Map.put(:uid, new_uid)
                    |> Map.put(:rrule, adjusted_rrule)
                    |> Map.put(:sequence, 0)
                    |> Map.put(:attendees, final_attendees)
                    |> Map.put(:organizer_email, org_email)
                    |> Map.put(:organizer_name, org_name)
                    |> Map.put(:timezone, following_tzid)
                    |> Map.put(:vtimezones, vtimezones)
                  )

                new_vt_blocks = ensure_vtimezone_blocks([], following_tzid)
                new_series_ics = wrap_vcalendar(new_vt_blocks, [new_master_vevent])

                {:split_put, truncated_master_ics, new_uid, new_series_ics, final_attendees}
              end
          end
        end
    end
  end

  @doc """
  Applies a recurring event deletion (`"single"`, `"following"`, or `"all"`):
  - `"single"`: Adds an `EXDATE` for `recurrence_id_iso` to the master `VEVENT` and drops any
    matching `RECURRENCE-ID` override, returning `{:single_put, updated_ics}`.
  - `"following"`: Returns `:delete_all` if deleting from the first occurrence; otherwise
    truncates the master `RRULE` with `UNTIL` right before `recurrence_id_iso`, returning
    `{:single_put, truncated_master_ics}`.
  - `"all"`: Returns `:delete_all`.
  """
  def apply_recurring_delete(_raw_ics, "all", _recurrence_id_iso), do: :delete_all

  def apply_recurring_delete(raw_ics, scope, recurrence_id_iso)
      when is_binary(raw_ics) and scope in ["single", "following"] do
    unfolded = unfold(raw_ics)
    vtimezones = parse_vtimezones(unfolded)

    vtimezone_blocks =
      unfolded
      |> extract_component_blocks("VTIMEZONE")
      |> Enum.map(fn inner -> "BEGIN:VTIMEZONE\r\n" <> String.trim(inner) <> "\r\nEND:VTIMEZONE" end)

    vevent_inners =
      unfolded
      |> extract_component_blocks("VEVENT")
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    {master_inner, other_inners} = split_master_and_overrides(vevent_inners)

    case master_inner do
      nil ->
        :delete_all

      master_block ->
        master_ev = parse_raw_vevent(master_block, vtimezones)
        {master_props, _, _, _} = extract_vevent_all_props(master_block)
        target_rec_iso = non_empty_trimmed(recurrence_id_iso)

        cond do
          is_nil(master_ev) or map_size(master_ev.rrule) == 0 or is_nil(target_rec_iso) ->
            :delete_all

          scope == "single" ->
            exdate_line =
              build_exdate_line(Map.get(master_props, "DTSTART"), target_rec_iso, vtimezones)

            master_with_exdate = master_block <> "\r\n" <> exdate_line

            kept_overrides =
              other_inners
              |> Enum.reject(fn inner ->
                override_matches_target?(inner, target_rec_iso, vtimezones)
              end)
              |> Enum.map(&("BEGIN:VEVENT\r\n" <> &1 <> "\r\nEND:VEVENT"))

            updated_ics =
              wrap_vcalendar(
                vtimezone_blocks,
                ["BEGIN:VEVENT\r\n" <> master_with_exdate <> "\r\nEND:VEVENT" | kept_overrides]
              )

            {:single_put, updated_ics}

          scope == "following" ->
            if first_occurrence?(master_ev.dtstart, target_rec_iso) do
              :delete_all
            else
              until_val = compute_until_before(master_ev.dtstart, target_rec_iso)
              truncated_master_inner = replace_master_rrule_until(master_block, master_ev.rrule_raw, until_val)

              kept_prior_overrides =
                other_inners
                |> Enum.filter(fn inner ->
                  override_before_target?(inner, target_rec_iso, vtimezones)
                end)
                |> Enum.map(&("BEGIN:VEVENT\r\n" <> &1 <> "\r\nEND:VEVENT"))

              truncated_master_ics =
                wrap_vcalendar(
                  vtimezone_blocks,
                  ["BEGIN:VEVENT\r\n" <> truncated_master_inner <> "\r\nEND:VEVENT" | kept_prior_overrides]
                )

              {:single_put, truncated_master_ics}
            end
        end
    end
  end

  defp wrap_vcalendar(vtimezone_blocks, vevent_blocks) do
    lines =
      [
        "BEGIN:VCALENDAR",
        "VERSION:2.0",
        "PRODID:-//Ukko//CalDAV Client//EN",
        "CALSCALE:GREGORIAN"
      ] ++ vtimezone_blocks ++ vevent_blocks ++ ["END:VCALENDAR", ""]

    Enum.join(lines, "\r\n")
  end

  defp split_master_and_overrides(vevent_inners) do
    Enum.reduce(vevent_inners, {nil, []}, fn inner, {master_acc, others_acc} ->
      {props, _} = extract_block_props(inner)
      has_rrule = not is_nil(Map.get(props, "RRULE"))
      has_rec_id = not is_nil(Map.get(props, "RECURRENCE-ID"))

      if is_nil(master_acc) and has_rrule and not has_rec_id do
        {inner, others_acc}
      else
        {master_acc, others_acc ++ [inner]}
      end
    end)
  end

  defp build_recurrence_id_line(master_dtstart_prop, target_rec_iso, vtimezones) do
    build_matching_dt_line("RECURRENCE-ID", master_dtstart_prop, target_rec_iso, vtimezones)
  end

  defp build_exdate_line(master_dtstart_prop, target_rec_iso, vtimezones) do
    build_matching_dt_line("EXDATE", master_dtstart_prop, target_rec_iso, vtimezones)
  end

  defp build_matching_dt_line(prop_name, master_dtstart_prop, target_rec_iso, vtimezones) do
    case master_dtstart_prop do
      {params, raw_val} ->
        val = String.trim(raw_val)
        tzid = extract_tzid(params)
        has_date_param = Enum.any?(params, fn p -> String.upcase(String.trim(p)) == "VALUE=DATE" end)

        cond do
          has_date_param or match?(<<_::binary-size(8)>>, val) ->
            date = iso_to_date(target_rec_iso) || Date.utc_today()
            "#{prop_name};VALUE=DATE:#{Calendar.strftime(date, "%Y%m%d")}"

          String.ends_with?(val, "Z") ->
            "#{prop_name}:#{iso8601_to_ical_utc(target_rec_iso)}"

          not is_nil(tzid) and tzid != "" ->
            utc_dt = parse_iso_dt(target_rec_iso) || DateTime.utc_now()
            local_ndt = utc_to_local_ndt(utc_dt, tzid, vtimezones)
            "#{prop_name};TZID=#{tzid}:#{Calendar.strftime(local_ndt, "%Y%m%dT%H%M%S")}"

          true ->
            utc_dt = parse_iso_dt(target_rec_iso) || DateTime.utc_now()
            local_ndt = utc_to_local_ndt(utc_dt, nil, vtimezones)
            "#{prop_name}:#{Calendar.strftime(local_ndt, "%Y%m%dT%H%M%S")}"
        end

      _ ->
        format_dt_prop(prop_name, target_rec_iso, nil, %{})
    end
  end

  defp resolve_organizer_meta(existing_ev, new_attrs) do
    explicit_email = non_empty_trimmed(Map.get(new_attrs, :organizer_email))
    explicit_name = non_empty_trimmed(Map.get(new_attrs, :organizer_name))

    existing_org = if existing_ev, do: Map.get(existing_ev, :organizer), else: nil
    existing_email = if is_map(existing_org), do: non_empty_trimmed(existing_org[:email]), else: nil
    existing_name = if is_map(existing_org), do: non_empty_trimmed(existing_org[:name]), else: nil

    org_email =
      explicit_email ||
        existing_email ||
        non_empty_trimmed(Application.get_env(:ukko, :thundermail_user)) ||
        ""

    org_name = explicit_name || existing_name || ""
    {org_email, org_name}
  end

  defp single_event_details_changed?(nil, _new_attrs), do: true

  defp single_event_details_changed?(existing_ev, new_attrs) do
    new_title = String.trim(to_string(Map.get(new_attrs, :title) || ""))
    new_loc = String.trim(to_string(Map.get(new_attrs, :location) || ""))
    new_desc = String.trim(to_string(Map.get(new_attrs, :description) || ""))
    new_rrule = sanitize_rrule(Map.get(new_attrs, :rrule))
    old_rrule = sanitize_rrule(Map.get(existing_ev, :rrule_raw))

    text_or_rrule_changed =
      String.trim(existing_ev.summary || "") != new_title or
        String.trim(existing_ev.location || "") != new_loc or
        String.trim(existing_ev.description || "") != new_desc or
        old_rrule != new_rrule

    if text_or_rrule_changed do
      true
    else
      not same_event_span?(existing_ev.dtstart, existing_ev.dtend, existing_ev.duration_sec, new_attrs.start, new_attrs.end)
    end
  end

  defp recurring_occurrence_changed?(master_ev, matching_override_ev, scope, target_rec_iso, new_attrs) do
    ref_ev = matching_override_ev || master_ev
    new_title = String.trim(to_string(Map.get(new_attrs, :title) || ""))
    new_loc = String.trim(to_string(Map.get(new_attrs, :location) || ""))
    new_desc = String.trim(to_string(Map.get(new_attrs, :description) || ""))

    rrule_changed =
      scope == "following" and
        sanitize_rrule(Map.get(new_attrs, :rrule)) != sanitize_rrule(Map.get(master_ev, :rrule_raw))

    text_changed =
      String.trim(ref_ev.summary || "") != new_title or
        String.trim(ref_ev.location || "") != new_loc or
        String.trim(ref_ev.description || "") != new_desc

    cond do
      rrule_changed or text_changed ->
        true

      not is_nil(matching_override_ev) ->
        not same_event_span?(
          matching_override_ev.dtstart,
          matching_override_ev.dtend,
          matching_override_ev.duration_sec,
          new_attrs.start,
          new_attrs.end
        )

      true ->
        not same_occurrence_span?(master_ev, target_rec_iso, new_attrs.start, new_attrs.end)
    end
  end

  defp same_event_span?({:date, %Date{} = old_s}, old_dtend, _dur_sec, new_start_iso, new_end_iso) do
    if all_day_iso?(new_start_iso) do
      old_e =
        case old_dtend do
          {:date, %Date{} = d} -> if Date.compare(d, old_s) in [:lt, :eq], do: Date.add(old_s, 1), else: d
          _ -> Date.add(old_s, 1)
        end

      new_s = iso_to_date(new_start_iso)
      new_e_raw = iso_to_date(new_end_iso || new_start_iso) || new_s

      new_e =
        if new_s && new_e_raw && Date.compare(new_e_raw, new_s) in [:lt, :eq],
          do: Date.add(new_s, 1),
          else: new_e_raw

      new_s == old_s and new_e == old_e
    else
      false
    end
  end

  defp same_event_span?({_, %DateTime{} = old_s_utc, _, _}, old_dtend, dur_sec, new_start_iso, new_end_iso) do
    if all_day_iso?(new_start_iso) do
      false
    else
      old_e_utc =
        case old_dtend do
          {_, %DateTime{} = dt, _, _} -> dt
          _ -> DateTime.add(old_s_utc, dur_sec || 3600, :second)
        end

      case {parse_iso_dt(new_start_iso), parse_iso_dt(new_end_iso || new_start_iso)} do
        {%DateTime{} = new_s, %DateTime{} = new_e} ->
          abs(DateTime.diff(new_s, old_s_utc, :second)) < 60 and
            abs(DateTime.diff(new_e, old_e_utc, :second)) < 60

        _ ->
          false
      end
    end
  end

  defp same_event_span?(_, _, _, _, _), do: false

  defp same_occurrence_span?(master_ev, target_rec_iso, new_start_iso, new_end_iso) do
    case master_ev.dtstart do
      {:date, %Date{} = orig_s} ->
        if all_day_iso?(new_start_iso) do
          day_span =
            case master_ev.dtend do
              {:date, %Date{} = orig_e} -> max(Date.diff(orig_e, orig_s), 1)
              _ -> 1
            end

          occ_s = iso_to_date(target_rec_iso)
          new_s = iso_to_date(new_start_iso)
          new_e = iso_to_date(new_end_iso || new_start_iso)

          occ_s != nil and new_s == occ_s and new_e == Date.add(occ_s, day_span)
        else
          false
        end

      {_, %DateTime{} = orig_s_utc, _, _} ->
        if all_day_iso?(new_start_iso) do
          false
        else
          master_dur =
            case master_ev.dtend do
              {_, %DateTime{} = orig_e_utc, _, _} -> max(DateTime.diff(orig_e_utc, orig_s_utc, :second), 0)
              _ -> master_ev.duration_sec || 3600
            end

          case {parse_iso_dt(target_rec_iso), parse_iso_dt(new_start_iso), parse_iso_dt(new_end_iso || new_start_iso)} do
            {%DateTime{} = occ_s, %DateTime{} = new_s, %DateTime{} = new_e} ->
              new_dur = max(DateTime.diff(new_e, new_s, :second), 0)
              abs(DateTime.diff(new_s, occ_s, :second)) < 60 and abs(new_dur - master_dur) < 60

            _ ->
              false
          end
        end

      _ ->
        false
    end
  end

  defp extract_dtstart_tzid({:local, _, _, tz}) when is_binary(tz) and tz != "", do: tz
  defp extract_dtstart_tzid(_), do: nil

  defp all_day_iso?(iso) when is_binary(iso) do
    trimmed = String.trim(iso)
    String.length(trimmed) == 10 and match?({:ok, _}, Date.from_iso8601(trimmed))
  end

  defp all_day_iso?(_), do: false

  defp choose_effective_tzid(requested_tz, fallback_tz, start_iso) do
    if all_day_iso?(start_iso) do
      nil
    else
      case supported_vtimezone(requested_tz) do
        {canonical_tzid, _vt_block} -> canonical_tzid
        nil -> non_empty_trimmed(fallback_tz)
      end
    end
  end

  defp ensure_vtimezone_blocks(existing_vt_blocks, nil), do: existing_vt_blocks
  defp ensure_vtimezone_blocks(existing_vt_blocks, ""), do: existing_vt_blocks

  defp ensure_vtimezone_blocks(existing_vt_blocks, tzid) when is_binary(tzid) do
    already_present =
      Enum.any?(existing_vt_blocks, fn vt ->
        case Regex.run(~r/^TZID(?:;[^:]*)?:(.*)$/m, vt, capture: :all_but_first) do
          [raw] -> String.upcase(clean_tzid(raw)) == String.upcase(clean_tzid(tzid))
          _ -> false
        end
      end)

    if already_present do
      existing_vt_blocks
    else
      case supported_vtimezone(tzid) do
        {_canonical, vt_block} -> existing_vt_blocks ++ [vt_block]
        nil -> existing_vt_blocks
      end
    end
  end

  defp supported_vtimezone(nil), do: nil

  defp supported_vtimezone(tzid) when is_binary(tzid) do
    cleaned = clean_tzid(tzid)
    up = String.upcase(cleaned)

    cond do
      up in ["", "UTC", "GMT", "ETC/UTC", "ETC/GMT", "Z"] ->
        nil

      up in ["AMERICA/LOS_ANGELES", "AMERICA/VANCOUVER", "AMERICA/TIJUANA", "US/PACIFIC", "CANADA/PACIFIC", "PST8PDT"] ->
        canonical = if String.contains?(cleaned, "/"), do: cleaned, else: "America/Los_Angeles"
        {canonical, us_dst_vtimezone(canonical, "-0800", "-0700", "PST", "PDT")}

      up in ["AMERICA/PHOENIX", "US/ARIZONA"] ->
        canonical = if String.contains?(cleaned, "/"), do: cleaned, else: "America/Phoenix"
        {canonical, fixed_vtimezone(canonical, "-0700", "MST")}

      up in ["AMERICA/DENVER", "AMERICA/EDMONTON", "AMERICA/BOISE", "US/MOUNTAIN", "MST7MDT"] ->
        canonical = if String.contains?(cleaned, "/"), do: cleaned, else: "America/Denver"
        {canonical, us_dst_vtimezone(canonical, "-0700", "-0600", "MST", "MDT")}

      up in ["AMERICA/CHICAGO", "AMERICA/WINNIPEG", "US/CENTRAL", "CST6CDT"] ->
        canonical = if String.contains?(cleaned, "/"), do: cleaned, else: "America/Chicago"
        {canonical, us_dst_vtimezone(canonical, "-0600", "-0500", "CST", "CDT")}

      up in ["AMERICA/NEW_YORK", "AMERICA/TORONTO", "AMERICA/DETROIT", "US/EASTERN", "EST5EDT"] ->
        canonical = if String.contains?(cleaned, "/"), do: cleaned, else: "America/New_York"
        {canonical, us_dst_vtimezone(canonical, "-0500", "-0400", "EST", "EDT")}

      up in ["AMERICA/ANCHORAGE", "US/ALASKA"] ->
        canonical = if String.contains?(cleaned, "/"), do: cleaned, else: "America/Anchorage"
        {canonical, us_dst_vtimezone(canonical, "-0900", "-0800", "AKST", "AKDT")}

      up in ["PACIFIC/HONOLULU", "US/HAWAII"] ->
        canonical = if String.contains?(cleaned, "/"), do: cleaned, else: "Pacific/Honolulu"
        {canonical, fixed_vtimezone(canonical, "-1000", "HST")}

      up in ["EUROPE/LONDON", "EUROPE/DUBLIN", "EUROPE/LISBON"] ->
        {cleaned, eu_dst_vtimezone(cleaned, "+0000", "+0100", "GMT", "BST")}

      up in [
        "EUROPE/PARIS",
        "EUROPE/BERLIN",
        "EUROPE/ROME",
        "EUROPE/MADRID",
        "EUROPE/AMSTERDAM",
        "EUROPE/ZURICH",
        "EUROPE/STOCKHOLM"
      ] ->
        {cleaned, eu_dst_vtimezone(cleaned, "+0100", "+0200", "CET", "CEST")}

      up in ["EUROPE/HELSINKI", "EUROPE/ATHENS", "EUROPE/KYIV"] ->
        {cleaned, eu_dst_vtimezone(cleaned, "+0200", "+0300", "EET", "EEST")}

      up == "ASIA/TOKYO" ->
        {cleaned, fixed_vtimezone(cleaned, "+0900", "JST")}

      up in ["ASIA/SHANGHAI", "ASIA/HONG_KONG", "ASIA/SINGAPORE", "ASIA/TAIPEI"] ->
        {cleaned, fixed_vtimezone(cleaned, "+0800", "CST")}

      up in ["ASIA/KOLKATA", "ASIA/CALCUTTA"] ->
        {cleaned, fixed_vtimezone(cleaned, "+0530", "IST")}

      true ->
        nil
    end
  end

  defp supported_vtimezone(_), do: nil

  defp us_dst_vtimezone(tzid, std_off, dst_off, std_name, dst_name) do
    Enum.join(
      [
        "BEGIN:VTIMEZONE",
        "TZID:#{tzid}",
        "BEGIN:DAYLIGHT",
        "TZOFFSETFROM:#{std_off}",
        "TZOFFSETTO:#{dst_off}",
        "TZNAME:#{dst_name}",
        "DTSTART:19700308T020000",
        "RRULE:FREQ=YEARLY;BYMONTH=3;BYDAY=2SU",
        "END:DAYLIGHT",
        "BEGIN:STANDARD",
        "TZOFFSETFROM:#{dst_off}",
        "TZOFFSETTO:#{std_off}",
        "TZNAME:#{std_name}",
        "DTSTART:19701101T020000",
        "RRULE:FREQ=YEARLY;BYMONTH=11;BYDAY=1SU",
        "END:STANDARD",
        "END:VTIMEZONE"
      ],
      "\r\n"
    )
  end

  defp eu_dst_vtimezone(tzid, std_off, dst_off, std_name, dst_name) do
    Enum.join(
      [
        "BEGIN:VTIMEZONE",
        "TZID:#{tzid}",
        "BEGIN:DAYLIGHT",
        "TZOFFSETFROM:#{std_off}",
        "TZOFFSETTO:#{dst_off}",
        "TZNAME:#{dst_name}",
        "DTSTART:19700329T010000",
        "RRULE:FREQ=YEARLY;BYMONTH=3;BYDAY=-1SU",
        "END:DAYLIGHT",
        "BEGIN:STANDARD",
        "TZOFFSETFROM:#{dst_off}",
        "TZOFFSETTO:#{std_off}",
        "TZNAME:#{std_name}",
        "DTSTART:19701025T020000",
        "RRULE:FREQ=YEARLY;BYMONTH=10;BYDAY=-1SU",
        "END:STANDARD",
        "END:VTIMEZONE"
      ],
      "\r\n"
    )
  end

  defp fixed_vtimezone(tzid, std_off, std_name) do
    Enum.join(
      [
        "BEGIN:VTIMEZONE",
        "TZID:#{tzid}",
        "BEGIN:STANDARD",
        "TZOFFSETFROM:#{std_off}",
        "TZOFFSETTO:#{std_off}",
        "TZNAME:#{std_name}",
        "DTSTART:19700101T000000",
        "END:STANDARD",
        "END:VTIMEZONE"
      ],
      "\r\n"
    )
  end

  defp utc_to_local_ndt(%DateTime{} = utc_dt, tzid, vtimezones) do
    utc_ndt = DateTime.to_naive(DateTime.shift_zone!(utc_dt, "Etc/UTC"))
    off1 = resolve_tz_offset_seconds(tzid, utc_ndt, vtimezones)
    approx_local = NaiveDateTime.add(utc_ndt, off1, :second)
    off2 = resolve_tz_offset_seconds(tzid, approx_local, vtimezones)
    NaiveDateTime.add(utc_ndt, off2, :second)
  end

  defp override_matches_target?(inner, target_rec_iso, vtimezones) do
    {props, _} = extract_block_props(inner)

    case parse_dt_prop(Map.get(props, "RECURRENCE-ID"), vtimezones) do
      nil ->
        false

      {:date, %Date{} = d} ->
        case iso_to_date(target_rec_iso) do
          %Date{} = td -> Date.compare(d, td) == :eq
          _ -> false
        end

      {_, %DateTime{} = dt, _, _} ->
        case parse_iso_dt(target_rec_iso) do
          %DateTime{} = tdt -> abs(DateTime.diff(dt, tdt, :second)) < 60
          _ -> false
        end
    end
  end

  defp override_before_target?(inner, target_rec_iso, vtimezones) do
    {props, _} = extract_block_props(inner)

    case parse_dt_prop(Map.get(props, "RECURRENCE-ID"), vtimezones) do
      nil ->
        false

      {:date, %Date{} = d} ->
        case iso_to_date(target_rec_iso) do
          %Date{} = td -> Date.compare(d, td) == :lt
          _ -> false
        end

      {_, %DateTime{} = dt, _, _} ->
        case parse_iso_dt(target_rec_iso) do
          %DateTime{} = tdt -> DateTime.diff(dt, tdt, :second) <= -60
          _ -> false
        end
    end
  end

  defp first_occurrence?({:date, %Date{} = master_d}, target_rec_iso) do
    case iso_to_date(target_rec_iso) do
      %Date{} = td -> Date.compare(td, master_d) in [:lt, :eq]
      _ -> false
    end
  end

  defp first_occurrence?({_, %DateTime{} = master_utc, _, _}, target_rec_iso) do
    case parse_iso_dt(target_rec_iso) do
      %DateTime{} = tdt -> DateTime.diff(tdt, master_utc, :second) <= 60
      _ -> false
    end
  end

  defp first_occurrence?(_, _), do: false

  defp compute_until_before({:date, _}, target_rec_iso) do
    target_d = iso_to_date(target_rec_iso) || Date.utc_today()
    Calendar.strftime(Date.add(target_d, -1), "%Y%m%d")
  end

  defp compute_until_before(_, target_rec_iso) do
    target_dt = parse_iso_dt(target_rec_iso) || DateTime.utc_now()
    iso8601_to_ical_utc(DateTime.add(target_dt, -1, :second))
  end

  defp replace_master_rrule_until(master_block, orig_rrule_raw, until_val) do
    kept_parts =
      orig_rrule_raw
      |> String.split(";", trim: true)
      |> Enum.reject(fn part ->
        case String.split(part, "=", parts: 2) do
          [k, _] -> String.upcase(String.trim(k)) in ["UNTIL", "COUNT"]
          _ -> false
        end
      end)

    new_rrule = Enum.join(kept_parts ++ ["UNTIL=#{until_val}"], ";")

    master_block
    |> :binary.split(["\r\n", "\n"], [:global, :trim_all])
    |> Enum.map(fn line ->
      if Regex.match?(~r/^RRULE(?:;[^:]*)?:/i, String.trim(line)) do
        "RRULE:#{new_rrule}"
      else
        line
      end
    end)
    |> Enum.join("\r\n")
  end

  defp adjust_rrule_for_following(
         master_ev,
         target_rec_iso,
         new_attrs,
         is_first,
         following_tzid,
         vtimezones
       ) do
    explicit_rrule = Map.get(new_attrs, :rrule)

    cond do
      # User explicitly selected "Does not repeat" in the edit modal
      is_binary(explicit_rrule) and String.trim(explicit_rrule) == "" ->
        nil

      # User explicitly chose a different RRULE preset in the edit modal
      is_binary(explicit_rrule) and sanitize_rrule(explicit_rrule) != sanitize_rrule(master_ev.rrule_raw) ->
        sanitize_rrule(explicit_rrule)

      true ->
        base_parts =
          master_ev.rrule_raw
          |> String.split(";", trim: true)
          |> Enum.map(fn part ->
            case String.split(part, "=", parts: 2) do
              [k, v] -> {String.upcase(String.trim(k)), String.trim(v)}
              _ -> nil
            end
          end)
          |> Enum.reject(&is_nil/1)

        freq =
          Enum.find_value(base_parts, "", fn
            {"FREQ", v} -> String.upcase(v)
            _ -> nil
          end)

        compare_tzid = following_tzid || extract_dtstart_tzid(master_ev.dtstart)
        old_date = iso_to_date_in_tz(target_rec_iso, master_ev.dtstart, compare_tzid, vtimezones)
        new_date = iso_to_date_in_tz(new_attrs.start, master_ev.dtstart, compare_tzid, vtimezones)

        shifted_parts =
          if old_date && new_date && Date.compare(old_date, new_date) != :eq do
            shift_rrule_parts(base_parts, freq, old_date, new_date)
          else
            base_parts
          end

        final_parts =
          if not is_first do
            split_master_date = master_occ_date(master_ev.dtstart, target_rec_iso, vtimezones)
            adjust_count_or_until_after_split(shifted_parts, master_ev, split_master_date, new_date)
          else
            shifted_parts
          end

        final_parts
        |> Enum.map(fn {k, v} -> "#{k}=#{v}" end)
        |> Enum.join(";")
    end
  end

  defp iso_to_date_in_tz(iso, _master_dtstart, _tzid, _vtimezones) when not is_binary(iso), do: nil

  defp iso_to_date_in_tz(iso, {:date, _}, _tzid, _vtimezones), do: iso_to_date(iso)

  defp iso_to_date_in_tz(iso, _master_dtstart, tzid, vtimezones) do
    cond do
      all_day_iso?(iso) ->
        iso_to_date(iso)

      is_binary(tzid) and tzid != "" ->
        case parse_iso_dt(iso) do
          %DateTime{} = utc_dt ->
            utc_dt |> utc_to_local_ndt(tzid, vtimezones) |> NaiveDateTime.to_date()

          _ ->
            iso_to_date(iso)
        end

      true ->
        iso_to_date(iso)
    end
  end

  defp master_occ_date({:date, _}, target_rec_iso, _vtimezones), do: iso_to_date(target_rec_iso)

  defp master_occ_date({:local, _, _, tzid}, target_rec_iso, vtimezones) do
    case parse_iso_dt(target_rec_iso) do
      %DateTime{} = utc_dt ->
        utc_dt |> utc_to_local_ndt(tzid, vtimezones) |> NaiveDateTime.to_date()

      _ ->
        iso_to_date(target_rec_iso)
    end
  end

  defp master_occ_date(_, target_rec_iso, _vtimezones), do: iso_to_date(target_rec_iso)

  defp shift_rrule_parts(parts, freq, %Date{} = old_date, %Date{} = new_date) do
    old_wd = weekday_code(Date.day_of_week(old_date))
    new_wd = weekday_code(Date.day_of_week(new_date))

    Enum.map(parts, fn
      {"BYDAY", val} when freq == "WEEKLY" ->
        updated_days =
          val
          |> String.split(",", trim: true)
          |> Enum.map(fn tok ->
            up = String.upcase(String.trim(tok))
            if up == old_wd, do: new_wd, else: up
          end)
          |> Enum.uniq()
          |> Enum.join(",")

        {"BYDAY", updated_days}

      {"BYDAY", val} when freq == "MONTHLY" ->
        case Regex.run(~r/^([+-]?\d+)(MO|TU|WE|TH|FR|SA|SU)$/i, String.trim(val), capture: :all_but_first) do
          [_nth, _wd] ->
            new_nth = div(new_date.day - 1, 7) + 1
            {"BYDAY", "#{new_nth}#{new_wd}"}

          _ ->
            {"BYDAY", val}
        end

      {"BYMONTHDAY", val} when freq in ["MONTHLY", "YEARLY"] ->
        if String.trim(val) == Integer.to_string(old_date.day) do
          {"BYMONTHDAY", Integer.to_string(new_date.day)}
        else
          {"BYMONTHDAY", val}
        end

      {"BYMONTH", val} when freq == "YEARLY" ->
        if String.trim(val) == Integer.to_string(old_date.month) do
          {"BYMONTH", Integer.to_string(new_date.month)}
        else
          {"BYMONTH", val}
        end

      other ->
        other
    end)
  end

  defp adjust_count_or_until_after_split(parts, master_ev, %Date{} = split_date, %Date{} = new_date) do
    Enum.flat_map(parts, fn
      {"COUNT", count_str} ->
        case parse_int(count_str, nil) do
          total when is_integer(total) and total > 0 ->
            start_d = extract_local_date(master_ev.dtstart)
            prior_dates =
              generate_rrule_dates(
                Map.delete(master_ev.rrule, "COUNT"),
                start_d,
                start_d,
                Date.add(split_date, -1),
                master_ev.exdates
              )

            remaining = max(total - length(prior_dates), 1)
            [{"COUNT", Integer.to_string(remaining)}]

          _ ->
            []
        end

      {"UNTIL", until_str} ->
        case parse_until_date(until_str) do
          %Date{} = ud ->
            if Date.compare(new_date, ud) == :gt, do: [], else: [{"UNTIL", until_str}]

          _ ->
            [{"UNTIL", until_str}]
        end

      other ->
        [other]
    end)
  end

  defp adjust_count_or_until_after_split(parts, _master_ev, _split_date, _new_date), do: parts

  defp iso_to_date(iso) when is_binary(iso) do
    trimmed = String.trim(iso)

    cond do
      String.length(trimmed) >= 10 and match?({:ok, _}, Date.from_iso8601(String.slice(trimmed, 0, 10))) ->
        {:ok, d} = Date.from_iso8601(String.slice(trimmed, 0, 10))
        d

      match?({:ok, _, _}, DateTime.from_iso8601(trimmed)) ->
        {:ok, dt, _} = DateTime.from_iso8601(trimmed)
        DateTime.to_date(dt)

      true ->
        nil
    end
  end

  defp iso_to_date(_), do: nil

  defp sanitize_rrule(nil), do: nil

  defp sanitize_rrule(rrule) when is_binary(rrule) do
    cleaned =
      rrule
      |> String.trim()
      |> String.replace(~r/^RRULE:/i, "")
      |> String.trim()

    if cleaned != "" and Regex.match?(~r/FREQ=/i, cleaned) do
      cleaned
    else
      nil
    end
  end

  defp sanitize_rrule(_), do: nil

  defp non_empty_trimmed(nil), do: nil

  defp non_empty_trimmed(s) when is_binary(s) do
    t = String.trim(s)
    if t == "", do: nil, else: t
  end

  defp non_empty_trimmed(_), do: nil

  @doc """
  Normalizes a list of attendee maps or strings into `%{name: String.t(), email: String.t(), status: String.t()}` maps.
  """
  def normalize_attendees(list) when is_list(list) do
    list
    |> Enum.map(fn
      att when is_map(att) ->
        email =
          (att[:email] || att["email"] || "")
          |> to_string()
          |> String.trim()
          |> String.replace(~r/^mailto:/i, "")

        name =
          (att[:name] || att["name"] || "")
          |> to_string()
          |> String.trim()

        status =
          (att[:status] || att["status"] || "NEEDS-ACTION")
          |> to_string()
          |> String.upcase()
          |> String.trim()

        %{name: name, email: email, status: if(status == "", do: "NEEDS-ACTION", else: status)}

      att when is_binary(att) ->
        trimmed = String.trim(att)

        case Regex.run(~r/^(.*)<([^>]+)>$/, trimmed, capture: :all_but_first) do
          [name_part, email_part] ->
            %{
              name: String.trim(name_part, " \""),
              email: String.trim(email_part),
              status: "NEEDS-ACTION"
            }

          _ ->
            %{name: "", email: trimmed, status: "NEEDS-ACTION"}
        end

      _ ->
        %{name: "", email: "", status: "NEEDS-ACTION"}
    end)
    |> Enum.filter(fn %{email: email} -> email != "" and String.contains?(email, "@") end)
    |> Enum.uniq_by(fn %{email: email} -> String.downcase(email) end)
  end

  def normalize_attendees(_), do: []

  defp build_participant_lines(_organizer_email, _organizer_name, []), do: []

  defp build_participant_lines(organizer_email, organizer_name, attendees) do
    org_trimmed = String.trim(to_string(organizer_email))
    org_name_trimmed = String.trim(to_string(organizer_name))

    organizer_lines =
      if org_trimmed != "" and String.contains?(org_trimmed, "@") do
        org_cn =
          if org_name_trimmed != "" and String.downcase(org_name_trimmed) != String.downcase(org_trimmed) do
            safe_org = String.replace(org_name_trimmed, "\"", "'")
            ~s(;CN="#{safe_org}")
          else
            ""
          end

        ["ORGANIZER#{org_cn}:mailto:#{org_trimmed}"]
      else
        []
      end

    attendee_lines =
      Enum.map(attendees, fn %{name: name, email: email, status: status} ->
        cn_param =
          if is_binary(name) and String.trim(name) != "" do
            safe_cn = String.replace(String.trim(name), "\"", "'")
            ~s(;CN="#{safe_cn}")
          else
            ""
          end

        partstat = if is_binary(status) and status != "", do: status, else: "NEEDS-ACTION"

        "ATTENDEE;CUTYPE=INDIVIDUAL;ROLE=REQ-PARTICIPANT;PARTSTAT=#{partstat};RSVP=TRUE#{cn_param}:mailto:#{email}"
      end)

    organizer_lines ++ attendee_lines
  end

  defp format_dt_prop(prop, iso, tzid, vtimezones) when is_binary(iso) do
    trimmed = String.trim(iso)

    cond do
      all_day_iso?(trimmed) ->
        {:ok, date} = Date.from_iso8601(trimmed)
        "#{prop};VALUE=DATE:#{Calendar.strftime(date, "%Y%m%d")}"

      is_binary(tzid) and String.trim(tzid) != "" ->
        clean_tz = clean_tzid(tzid)

        case parse_iso_dt(trimmed) do
          %DateTime{} = utc_dt ->
            local_ndt = utc_to_local_ndt(utc_dt, clean_tz, vtimezones || %{})
            "#{prop};TZID=#{clean_tz}:#{Calendar.strftime(local_ndt, "%Y%m%dT%H%M%S")}"

          _ ->
            "#{prop}:#{iso8601_to_ical_utc(trimmed)}"
        end

      true ->
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

  @doc """
  Cleans a stored `X-UKKO-LOCATION-URL` value, stripping any RFC 5545 backslash
  escapes (`\\,`, `\\;`, `\\`) added by CalDAV servers that re-serialize `X-*`
  properties as `TEXT`, and healing browser-normalized `/,` inside coordinate pairs
  (e.g. `34.00752/,-118.12667` -> `34.00752,-118.12667`).
  """
  def sanitize_location_url(nil), do: nil

  def sanitize_location_url(url) when is_binary(url) do
    cleaned =
      url
      |> unescape_text()
      |> String.trim()
      |> String.replace("\\", "")
      |> then(fn s -> Regex.replace(~r/(\d)\/,(-?\d)/, s, "\\1,\\2") end)

    if cleaned == "", do: nil, else: cleaned
  end
end
