defmodule Ukko.FastCache do
  @moduledoc """
  High-speed ETS cache with Stale-While-Revalidate (SWR) background refresh,
  startup cache warming, and fast binary XML tag extraction for CalDAV/CardDAV.
  """

  use GenServer

  @table :ukko_fast_cache
  @caldav_key :primary_caldav_parsed
  @contacts_key :carddav_contacts

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  @doc """
  Fetches `key` from ETS with Stale-While-Revalidate semantics:
  - Fresh hit (`now < fresh_until`): returns `{:ok, value}` in <0.1 ms.
  - Stale hit (`now >= fresh_until` and `force_refresh == false`): immediately returns
    `{:ok, stale_value}` and spawns a single deduplicated background task to refresh ETS.
  - Cold miss or `force_refresh == true`: runs `fetcher.()` synchronously and caches `{:ok, val}`.
  """
  def fetch_swr(key, soft_ttl_seconds, force_refresh \\ false, fetcher)
      when is_integer(soft_ttl_seconds) and is_function(fetcher, 0) do
    if :ets.whereis(@table) == :undefined do
      fetcher.()
    else
      now = System.system_time(:second)

      if force_refresh do
        run_and_store(key, soft_ttl_seconds, now, fetcher)
      else
        case :ets.lookup(@table, key) do
          [{^key, val, fresh_until}] when fresh_until > now ->
            {:ok, val}

          [{^key, stale_val, _expired_at}] ->
            trigger_background_refresh(key, soft_ttl_seconds, fetcher)
            {:ok, stale_val}

          [] ->
            run_and_store(key, soft_ttl_seconds, now, fetcher)
        end
      end
    end
  end

  @doc """
  Simple TTL lookup/store for lightweight request caches (e.g. MapQuest autocomplete).
  """
  def fetch_ttl(key, ttl_seconds, fetcher)
      when is_integer(ttl_seconds) and is_function(fetcher, 0) do
    if :ets.whereis(@table) == :undefined do
      fetcher.()
    else
      now = System.system_time(:second)

      case :ets.lookup(@table, key) do
        [{^key, val, expires_at}] when expires_at > now ->
          {:ok, val}

        _ ->
          run_and_store(key, ttl_seconds, now, fetcher)
      end
    end
  end

  @doc """
  Deletes a key (and any refresh lock) from ETS.
  """
  def delete(key) do
    if :ets.whereis(@table) != :undefined do
      :ets.delete(@table, key)
      :ets.delete(@table, {:refresh_lock, key})
    end

    :ok
  end

  def caldav_key, do: @caldav_key
  def contacts_key, do: @contacts_key

  def invalidate_caldav, do: delete(@caldav_key)
  def invalidate_contacts, do: delete(@contacts_key)

  @doc """
  Extracts inner text bodies of `<ns:local_name ...>...</ns:local_name>` tags directly from
  a UTF-8 XML binary without `:xmerl` charlist DOM allocation overhead.
  Handles both `<![CDATA[...]]>` blocks and XML character entities.
  """
  def extract_xml_tag_bodies(xml, local_name)
      when is_binary(xml) and is_binary(local_name) do
    escaped = Regex.escape(local_name)

    pattern =
      Regex.compile!(
        "<(?:[A-Za-z0-9_.-]+:)?#{escaped}(?:\\s[^>]*)?>(.*?)</(?:[A-Za-z0-9_.-]+:)?#{escaped}\\s*>",
        "is"
      )

    Regex.scan(pattern, xml, capture: :all_but_first)
    |> Enum.map(fn [raw_inner] -> decode_xml_text_or_cdata(raw_inner) end)
  end

  defp decode_xml_text_or_cdata(raw) when is_binary(raw) do
    if String.contains?(raw, "<![CDATA[") do
      ~r/<!\[CDATA\[.*?\]\]>/s
      |> Regex.split(raw, include_captures: true)
      |> Enum.map(fn segment ->
        if String.starts_with?(segment, "<![CDATA[") and String.ends_with?(segment, "]]>") do
          binary_part(segment, 9, byte_size(segment) - 12)
        else
          unescape_xml_entities(segment)
        end
      end)
      |> IO.iodata_to_binary()
    else
      unescape_xml_entities(raw)
    end
  end

  defp unescape_xml_entities(str) when is_binary(str) do
    if String.contains?(str, "&") do
      str
      |> String.replace("&#13;", "\r")
      |> String.replace("&#x0D;", "\r")
      |> String.replace("&#x0d;", "\r")
      |> String.replace("&#10;", "\n")
      |> String.replace("&#x0A;", "\n")
      |> String.replace("&#x0a;", "\n")
      |> String.replace("&lt;", "<")
      |> String.replace("&gt;", ">")
      |> String.replace("&quot;", "\"")
      |> String.replace("&apos;", "'")
      |> String.replace("&amp;", "&")
    else
      str
    end
  end

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

    caldav_url = Application.get_env(:ukko, :thundermail_caldav_url)

    if is_binary(caldav_url) and String.trim(caldav_url) != "" do
      Process.send_after(self(), :warm_caches, 400)
    end

    {:ok, %{}}
  end

  @impl true
  def handle_info(:warm_caches, state) do
    Task.start(fn ->
      _ = Ukko.CalDAV.warm_cache()
    end)

    Task.start(fn ->
      _ = Ukko.CardDAV.list_contacts()
    end)

    Task.start(fn ->
      _ = Ukko.Subscriptions.warm_all_async()
    end)

    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # --- Internal Helpers ---

  defp run_and_store(key, ttl_seconds, now, fetcher) do
    case fetcher.() do
      {:ok, val} ->
        :ets.insert(@table, {key, val, now + ttl_seconds})
        {:ok, val}

      {:error, _} = err ->
        err
    end
  end

  defp trigger_background_refresh(key, soft_ttl_seconds, fetcher) do
    now = System.system_time(:second)
    lock_key = {:refresh_lock, key}

    can_acquire =
      case :ets.lookup(@table, lock_key) do
        [{^lock_key, lock_until}] when lock_until > now ->
          false

        [{^lock_key, _expired}] ->
          :ets.delete(@table, lock_key)
          :ets.insert_new(@table, {lock_key, now + 30})

        [] ->
          :ets.insert_new(@table, {lock_key, now + 30})
      end

    if can_acquire do
      Task.start(fn ->
        try do
          case fetcher.() do
            {:ok, val} ->
              :ets.insert(@table, {key, val, System.system_time(:second) + soft_ttl_seconds})

            _ ->
              :ok
          end
        after
          if :ets.whereis(@table) != :undefined do
            :ets.delete(@table, lock_key)
          end
        end
      end)
    end

    :ok
  end
end
