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

    raw_vevents
    |> Enum.flat_map(fn ev ->
      if map_size(ev.rrule) == 0 and not single_event_in_rough_range?(ev.dtstart, ev.dtend, range_start_dt, range_end_dt) do
        []
      else
        override_keys = Map.get(recurrence_overrides, ev.uid, MapSet.new())
        expand_vevent(ev, vtimezones, range_start_dt, range_end_dt, override_keys, extra_meta)
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
          dtstart: dtstart_info,
          dtend: dtend_info,
          duration_sec: duration_sec,
          rrule: parse_rrule_map(rrule_str),
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
  defp recurrence_match_key({:utc, %DateTime{} = dt, _ndt, _tz}), do: {:date, Date.to_iso8601(DateTime.to_date(dt))}
  defp recurrence_match_key({:local, _dt, %NaiveDateTime{} = ndt, _tz}), do: {:date, Date.to_iso8601(NaiveDateTime.to_date(ndt))}
  defp recurrence_match_key(_), do: :none

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
    occurrence_dates = generate_rrule_dates(ev.rrule, start_date, win_start_date, win_end_date, excluded)

    Enum.map(occurrence_dates, fn occ_date ->
      case ev.dtstart do
        {:date, %Date{} = orig_s} ->
          day_span =
            case ev.dtend do
              {:date, %Date{} = orig_e} -> max(Date.diff(orig_e, orig_s), 1)
              _ -> 1
            end

          s_iso = Date.to_iso8601(occ_date)
          e_iso = Date.to_iso8601(Date.add(occ_date, day_span))
          decorate_event_map(ev, s_iso, e_iso, true, extra_meta)

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

          occ_e_utc = DateTime.add(occ_s_utc, duration_sec, :second)
          decorate_event_map(ev, format_utc_iso(occ_s_utc), format_utc_iso(occ_e_utc), false, extra_meta)
      end
    end)
  end

  defp generate_rrule_dates(rrule, %Date{} = start_date, win_start, win_end, excluded) do
    freq = String.upcase(Map.get(rrule, "FREQ", ""))
    interval = max(parse_int(Map.get(rrule, "INTERVAL"), 1), 1)
    max_count = parse_int(Map.get(rrule, "COUNT"), nil)
    until_date = parse_until_date(Map.get(rrule, "UNTIL"))

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

    base = %{
      id: "#{id_prefix}::#{start_str}",
      uid: ev.uid,
      title: ev.summary,
      start: start_str,
      end: end_str,
      allDay: all_day,
      description: ev.description,
      location: ev.location,
      organizer: Map.get(ev, :organizer),
      attendees: Map.get(ev, :attendees, []),
      readOnly: read_only,
      calendarName: calendar_name,
      subscriptionId: sub_id,
      extendedProps: %{
        uid: ev.uid,
        description: ev.description,
        location: ev.location,
        organizer: Map.get(ev, :organizer),
        attendees: Map.get(ev, :attendees, []),
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

  defp parse_until_date(nil), do: nil

  defp parse_until_date(str) when is_binary(str) do
    case parse_date_ical(String.slice(String.trim(str), 0, 8)) do
      {:ok, d} -> d
      _ -> nil
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
  Builds an RFC 5545 `.ics` VCALENDAR string for a single event.
  Supports optional `:attendees` (list of `%{name, email, status}` maps or email strings)
  and `:organizer_email`.
  """
  def build_ics(%{uid: uid, title: title, start: start_iso, end: end_iso} = attrs) do
    description = Map.get(attrs, :description) || ""
    location = Map.get(attrs, :location) || ""
    attendees = normalize_attendees(Map.get(attrs, :attendees) || [])
    organizer_email =
      Map.get(attrs, :organizer_email) ||
        Application.get_env(:ukko, :thundermail_user) ||
        ""

    dtstamp = iso8601_to_ical_utc(DateTime.utc_now())
    dtstart = format_dt_prop("DTSTART", start_iso)
    dtend = format_dt_prop("DTEND", end_iso || start_iso)

    participant_lines = build_participant_lines(organizer_email, attendees)

    lines =
      [
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
        "LOCATION:#{escape_text(location)}"
      ] ++
        participant_lines ++
        [
          "END:VEVENT",
          "END:VCALENDAR",
          ""
        ]

    Enum.join(lines, "\r\n")
  end

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

  defp build_participant_lines(_organizer_email, []), do: []

  defp build_participant_lines(organizer_email, attendees) do
    org_trimmed = String.trim(to_string(organizer_email))

    organizer_lines =
      if org_trimmed != "" and String.contains?(org_trimmed, "@") do
        ["ORGANIZER:mailto:#{org_trimmed}"]
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
