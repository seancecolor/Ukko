defmodule Ukko.Subscriptions do
  @moduledoc """
  Manages external iCal (`.ics`) calendar subscriptions (such as Google Calendar feeds)
  and the user's published `.ics` feed token, persisting configuration to the CalDAV server
  (`ukko-subscriptions-config.ics`) and caching feeds in ETS.
  """

  use GenServer
  alias Ukko.{CalDAV, ICal}

  @table :ukko_subscriptions_cache
  @config_uid "ukko-subscriptions-config"
  @feed_ttl_seconds 600
  @default_color "#9333ea"

  # --- Client API ---

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  @doc """
  Returns the secret token used to publish the user's primary calendar as a subscribable `.ics` URL.
  """
  def get_feed_token do
    case :ets.lookup(@table, :feed_token) do
      [{:feed_token, token}] when is_binary(token) and token != "" ->
        token

      _ ->
        GenServer.call(__MODULE__, :get_feed_token, 15_000)
    end
  rescue
    _ -> default_feed_token()
  end

  @doc """
  Rotates the secret `.ics` feed token, invalidating the previous share URL.
  """
  def rotate_feed_token do
    GenServer.call(__MODULE__, :rotate_feed_token, 15_000)
  end

  @doc """
  Verifies whether a candidate token matches the active `.ics` feed token.
  """
  def valid_feed_token?(candidate) when is_binary(candidate) do
    expected = get_feed_token()

    byte_size(candidate) > 0 and
      byte_size(candidate) == byte_size(expected) and
      Plug.Crypto.secure_compare(candidate, expected)
  end

  def valid_feed_token?(_), do: false

  @doc """
  Returns the list of configured calendar subscriptions.
  """
  def list_subscriptions do
    case :ets.lookup(@table, :subscriptions) do
      [{:subscriptions, subs}] when is_list(subs) ->
        subs

      _ ->
        GenServer.call(__MODULE__, :load_subscriptions, 15_000)
    end
  rescue
    _ -> []
  end

  @doc """
  Adds a new `.ics` calendar subscription after validating and fetching its feed.
  """
  def add_subscription(params) when is_map(params) do
    raw_url = Map.get(params, "url") || Map.get(params, :url) || ""
    raw_name = Map.get(params, "name") || Map.get(params, :name) || ""
    raw_color = Map.get(params, "color") || Map.get(params, :color) || @default_color

    url = normalize_subscription_url(raw_url)

    if url == "" do
      {:error, "Calendar URL is required."}
    else
      case fetch_remote_ics(url, true) do
        {:ok, ics_body} ->
          inferred_name =
            case String.trim(to_string(raw_name)) do
              "" -> extract_calname(ics_body) || "Subscribed Calendar"
              n -> n
            end

          sub = %{
            "id" => "sub-" <> ICal.generate_uid(),
            "name" => inferred_name,
            "url" => url,
            "color" => normalize_color(raw_color),
            "enabled" => true
          }

          GenServer.call(__MODULE__, {:put_subscription, sub}, 15_000)

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @doc """
  Updates an existing subscription's `name`, `color`, `url`, or `enabled` flag.
  """
  def update_subscription(id, params) when is_binary(id) and is_map(params) do
    GenServer.call(__MODULE__, {:update_subscription, id, params}, 15_000)
  end

  @doc """
  Deletes a subscription by `id`.
  """
  def delete_subscription(id) when is_binary(id) do
    GenServer.call(__MODULE__, {:delete_subscription, id}, 15_000)
  end

  @doc """
  Fetches and parses events from all enabled subscribed calendars within `[start_iso, end_iso]`.
  """
  def fetch_events(start_iso \\ nil, end_iso \\ nil) do
    subs =
      list_subscriptions()
      |> Enum.filter(fn sub -> Map.get(sub, "enabled", true) != false end)

    if subs == [] do
      []
    else
      subs
      |> Task.async_stream(
        fn sub ->
          url = Map.get(sub, "url", "")

          case fetch_remote_parsed_calendar(url, false) do
            {:ok, parsed_cal} ->
              ICal.expand_parsed_calendar(parsed_cal, start_iso, end_iso, %{
                color: Map.get(sub, "color", @default_color),
                calendar_name: Map.get(sub, "name", "Subscribed Calendar"),
                subscription_id: Map.get(sub, "id"),
                read_only: true
              })

            {:error, _} ->
              []
          end
        end,
        timeout: 15_000,
        on_timeout: :kill_task
      )
      |> Enum.flat_map(fn
        {:ok, evs} when is_list(evs) -> evs
        _ -> []
      end)
    end
  rescue
    _ -> []
  end

  @doc """
  Normalizes user-provided Google Calendar / WebCal / iCal URLs.
  """
  def normalize_subscription_url(raw) when is_binary(raw) do
    trimmed = String.trim(raw)

    cond do
      trimmed == "" ->
        ""

      String.starts_with?(String.downcase(trimmed), "webcal://") ->
        "https://" <> String.slice(trimmed, 9..-1//1)

      String.starts_with?(String.downcase(trimmed), "webcals://") ->
        "https://" <> String.slice(trimmed, 10..-1//1)

      # Google Calendar HTML embed link with ?src=...
      String.contains?(trimmed, "calendar.google.com/calendar") and
          not String.ends_with?(trimmed, ".ics") and
          String.contains?(trimmed, "src=") ->
        case URI.parse(trimmed) do
          %URI{query: query} when is_binary(query) ->
            params = URI.decode_query(query)

            case Map.get(params, "src") do
              src when is_binary(src) and src != "" ->
                "https://calendar.google.com/calendar/ical/#{URI.encode_www_form(src)}/public/basic.ics"

              _ ->
                trimmed
            end

          _ ->
            trimmed
        end

      # Plain email address (e.g. wife's Gmail address)
      Regex.match?(~r/^[^\s@]+@[^\s@]+\.[^\s@]+$/, trimmed) ->
        "https://calendar.google.com/calendar/ical/#{URI.encode_www_form(trimmed)}/public/basic.ics"

      true ->
        trimmed
    end
  end

  def normalize_subscription_url(_), do: ""

  # --- GenServer Callbacks ---

  @impl true
  def init(:ok) do
    :ets.new(@table, [
      :named_table,
      :set,
      :public,
      read_concurrency: true,
      write_concurrency: true
    ])

    {:ok, %{}}
  end

  @impl true
  def handle_call(:load_subscriptions, _from, state) do
    {subs, _token} = ensure_loaded()
    {:reply, subs, state}
  end

  @impl true
  def handle_call(:get_feed_token, _from, state) do
    {_subs, token} = ensure_loaded()
    {:reply, token, state}
  end

  @impl true
  def handle_call(:rotate_feed_token, _from, state) do
    {subs, _old_token} = ensure_loaded()

    new_token =
      :crypto.strong_rand_bytes(24)
      |> Base.url_encode64(padding: false)

    :ets.insert(@table, {:feed_token, new_token})
    save_to_caldav_async(subs, new_token)
    {:reply, {:ok, new_token}, state}
  end

  @impl true
  def handle_call({:put_subscription, new_sub}, _from, state) do
    {current, token} = ensure_loaded()

    updated =
      current
      |> Enum.reject(fn s -> Map.get(s, "url") == Map.get(new_sub, "url") end)
      |> Kernel.++([new_sub])

    :ets.insert(@table, {:subscriptions, updated})
    save_to_caldav_async(updated, token)
    {:reply, {:ok, new_sub}, state}
  end

  @impl true
  def handle_call({:update_subscription, id, params}, _from, state) do
    {current, token} = ensure_loaded()

    case Enum.find(current, fn s -> Map.get(s, "id") == id end) do
      nil ->
        {:reply, {:error, :not_found}, state}

      existing ->
        updated_sub =
          existing
          |> maybe_put_str("name", params)
          |> maybe_put_color(params)
          |> maybe_put_enabled(params)

        updated_list =
          Enum.map(current, fn s ->
            if Map.get(s, "id") == id, do: updated_sub, else: s
          end)

        :ets.insert(@table, {:subscriptions, updated_list})
        save_to_caldav_async(updated_list, token)
        {:reply, {:ok, updated_sub}, state}
    end
  end

  @impl true
  def handle_call({:delete_subscription, id}, _from, state) do
    {current, token} = ensure_loaded()
    updated = Enum.reject(current, fn s -> Map.get(s, "id") == id end)
    :ets.insert(@table, {:subscriptions, updated})
    save_to_caldav_async(updated, token)
    {:reply, :ok, state}
  end

  # --- Internal Helpers ---

  defp ensure_loaded do
    subs_lookup = :ets.lookup(@table, :subscriptions)
    token_lookup = :ets.lookup(@table, :feed_token)

    case {subs_lookup, token_lookup} do
      {[{:subscriptions, subs}], [{:feed_token, token}]}
      when is_list(subs) and is_binary(token) and token != "" ->
        {subs, token}

      _ ->
        {loaded_subs, loaded_token} = load_from_caldav()
        :ets.insert(@table, {:subscriptions, loaded_subs})
        :ets.insert(@table, {:feed_token, loaded_token})
        {loaded_subs, loaded_token}
    end
  end

  defp default_feed_token do
    url = Application.get_env(:ukko, :thundermail_caldav_url) || ""
    user = Application.get_env(:ukko, :thundermail_user) || ""
    passcode = Application.get_env(:ukko, :auth_passcode) || "ukko-default"
    secret = "#{url}|#{user}|#{passcode}"

    :crypto.mac(:hmac, :sha256, secret, "ukko-primary-ical-feed-v1")
    |> Base.url_encode64(padding: false)
    |> binary_part(0, 32)
  end

  defp maybe_put_str(sub, key, params) do
    case Map.get(params, key) || Map.get(params, String.to_atom(key)) do
      val when is_binary(val) ->
        trimmed = String.trim(val)
        if trimmed == "", do: sub, else: Map.put(sub, key, trimmed)

      _ ->
        sub
    end
  end

  defp maybe_put_color(sub, params) do
    case Map.get(params, "color") || Map.get(params, :color) do
      val when is_binary(val) and val != "" -> Map.put(sub, "color", normalize_color(val))
      _ -> sub
    end
  end

  defp maybe_put_enabled(sub, params) do
    cond do
      Map.has_key?(params, "enabled") ->
        Map.put(sub, "enabled", params["enabled"] != false and params["enabled"] != "false")

      Map.has_key?(params, :enabled) ->
        Map.put(sub, "enabled", params[:enabled] != false and params[:enabled] != "false")

      true ->
        sub
    end
  end

  defp normalize_color(color) when is_binary(color) do
    trimmed = String.trim(color)
    if Regex.match?(~r/^#[0-9a-fA-F]{3,8}$/, trimmed), do: trimmed, else: @default_color
  end

  defp normalize_color(_), do: @default_color

  defp fetch_remote_parsed_calendar(url, bypass_cache) do
    now = System.system_time(:second)

    cached_parsed =
      if bypass_cache do
        nil
      else
        case :ets.lookup(@table, {:parsed_feed, url}) do
          [{{:parsed_feed, ^url}, parsed_cal, expires_at}] when expires_at > now ->
            parsed_cal

          _ ->
            nil
        end
      end

    if not is_nil(cached_parsed) do
      {:ok, cached_parsed}
    else
      case fetch_remote_ics(url, bypass_cache) do
        {:ok, ics_str} ->
          parsed_cal = ICal.parse_calendar_data(ics_str)
          :ets.insert(@table, {{:parsed_feed, url}, parsed_cal, now + @feed_ttl_seconds})
          {:ok, parsed_cal}

        {:error, reason} ->
          # Fallback to stale parsed calendar in ETS if available
          case :ets.lookup(@table, {:parsed_feed, url}) do
            [{{:parsed_feed, ^url}, stale_parsed, _}] -> {:ok, stale_parsed}
            _ -> {:error, reason}
          end
      end
    end
  end

  defp fetch_remote_ics(url, bypass_cache) do
    now = System.system_time(:second)

    cached =
      if bypass_cache do
        nil
      else
        case :ets.lookup(@table, {:feed, url}) do
          [{{:feed, ^url}, body, expires_at}] when expires_at > now -> body
          _ -> nil
        end
      end

    if is_binary(cached) do
      {:ok, cached}
    else
      case Req.get(url, decode_body: false, receive_timeout: 20_000) do
        {:ok, %Req.Response{status: 200, body: body}} ->
          ics_str = to_string(body)

          if String.contains?(ics_str, "BEGIN:VCALENDAR") do
            parsed_cal = ICal.parse_calendar_data(ics_str)
            :ets.insert(@table, {{:feed, url}, ics_str, now + @feed_ttl_seconds})
            :ets.insert(@table, {{:parsed_feed, url}, parsed_cal, now + @feed_ttl_seconds})
            {:ok, ics_str}
          else
            {:error,
             "The URL did not return a valid iCalendar (.ics) feed. Make sure you copied the 'Secret address in iCal format' (.ics URL) from Google Calendar."}
          end

        {:ok, %Req.Response{status: 404}} ->
          if String.contains?(url, "calendar.google.com") do
            {:error,
             "Google Calendar returned 404 (Calendar is private). In Google Calendar → Settings → click the calendar → scroll to 'Integrate calendar' → copy the 'Secret address in iCal format' (.ics URL) and paste it here."}
          else
            {:error, "Calendar feed returned HTTP 404 Not Found."}
          end

        {:ok, %Req.Response{status: status}} ->
          {:error, "Calendar feed returned HTTP #{status}."}

        {:error, exception} ->
          {:error, "Failed to reach calendar URL: #{Exception.message(exception)}"}
      end
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  defp extract_calname(ics_body) when is_binary(ics_body) do
    case Regex.run(~r/^X-WR-CALNAME(?:;[^:]*)?:(.*)$/m, ics_body, capture: :all_but_first) do
      [name] ->
        cleaned = String.trim(name)
        if cleaned == "", do: nil, else: cleaned

      _ ->
        nil
    end
  end

  defp load_from_caldav do
    case CalDAV.get_raw_ics(@config_uid) do
      {:ok, ics_text} ->
        decode_config_ics(ics_text)

      _ ->
        {[], default_feed_token()}
    end
  end

  defp save_to_caldav_async(subs, feed_token) do
    Task.start(fn ->
      save_to_caldav(subs, feed_token)
    end)

    :ok
  end

  defp save_to_caldav(subs, feed_token) when is_list(subs) and is_binary(feed_token) do
    payload = %{
      "subscriptions" => subs,
      "feed_token" => feed_token
    }

    json_str = Jason.encode!(payload)
    b64 = Base.encode64(json_str)

    ics =
      ICal.build_ics(%{
        uid: @config_uid,
        title: "Ukko Subscriptions Config",
        start: "1970-01-01T00:00:00Z",
        end: "1970-01-01T00:00:00Z",
        description: "UKKO_SUBS_B64:" <> b64,
        location: ""
      })

    _ = CalDAV.put_raw_ics(@config_uid, ics)
    :ok
  rescue
    _ -> :ok
  end

  defp decode_config_ics(ics_text) when is_binary(ics_text) do
    unfolded = String.replace(ics_text, ~r/\r?\n[ \t]/, "")

    case Regex.run(~r/UKKO_SUBS_B64:([A-Za-z0-9+\/=]+)/, unfolded, capture: :all_but_first) do
      [b64] ->
        with {:ok, json} <- Base.decode64(b64),
             {:ok, decoded} <- Jason.decode(json) do
          case decoded do
            %{"subscriptions" => list} = map when is_list(list) ->
              tok = Map.get(map, "feed_token")
              valid_tok = if is_binary(tok) and tok != "", do: tok, else: default_feed_token()
              {list, valid_tok}

            list when is_list(list) ->
              {list, default_feed_token()}

            _ ->
              {[], default_feed_token()}
          end
        else
          _ -> {[], default_feed_token()}
        end

      _ ->
        {[], default_feed_token()}
    end
  end
end
