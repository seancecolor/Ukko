defmodule Ukko.MapQuest do
  @moduledoc """
  MapQuest Search Ahead (Autocomplete) client and URL builder (`developer.mapquest.com`).
  """

  alias Ukko.FastCache

  @prediction_url "https://www.mapquestapi.com/search/v3/prediction"
  @mapquest_web_base "https://www.mapquest.com"
  @autocomplete_ttl_seconds 3600

  @doc """
  Queries MapQuest's Search Ahead v3 Prediction API (`address,poi,adminArea,airport`)
  with a 1-hour ETS cache per query prefix and returns `%{display, name, type, url}` maps.
  """
  def autocomplete(query, limit \\ 6)

  def autocomplete(query, limit) when is_binary(query) do
    trimmed = String.trim(query)

    if String.length(trimmed) < 2 do
      {:ok, []}
    else
      cache_key = {:mapquest_q, String.downcase(trimmed), limit}

      FastCache.fetch_ttl(cache_key, @autocomplete_ttl_seconds, fn ->
        fetch_autocomplete_uncached(trimmed, limit)
      end)
    end
  rescue
    e -> {:error, {:exception, Exception.message(e)}}
  end

  def autocomplete(_, _), do: {:ok, []}

  defp fetch_autocomplete_uncached(trimmed, limit) do
    with {:ok, api_key} <- get_api_key() do
      params = [
        key: api_key,
        q: trimmed,
        collection: "address,poi,adminArea,airport",
        limit: limit
      ]

      case Req.get(@prediction_url,
             params: params,
             receive_timeout: 5_000,
             connect_options: [timeout: 4_000]
           ) do
        {:ok, %Req.Response{status: 200, body: %{"results" => results}}}
        when is_list(results) ->
          {:ok, parse_prediction_results(results)}

        {:ok, %Req.Response{status: 200, body: body}} when is_binary(body) ->
          case Jason.decode(body) do
            {:ok, %{"results" => results}} when is_list(results) ->
              {:ok, parse_prediction_results(results)}

            _ ->
              {:ok, []}
          end

        {:ok, %Req.Response{status: status, body: body}} ->
          {:error, {:mapquest_error, status, body}}

        {:error, exception} ->
          {:error, exception}
      end
    end
  end

  @doc """
  Parses raw MapQuest Search Ahead `results` list into normalized maps.
  """
  def parse_prediction_results(results) when is_list(results) do
    results
    |> Enum.map(fn item ->
      display = String.trim(to_string(item["displayString"] || item["name"] || ""))
      name = String.trim(to_string(item["name"] || display))
      record_type = String.trim(to_string(item["recordType"] || "address"))
      slug = item["slug"]

      if display == "" do
        nil
      else
        %{
          display: display,
          name: name,
          type: record_type,
          url: build_url(slug, display)
        }
      end
    end)
    |> Enum.reject(&is_nil/1)
  end

  def parse_prediction_results(_), do: []

  @doc """
  Builds a MapQuest web URL from an optional prediction `slug` or fallback query text.
  """
  def build_url(slug, display) when is_binary(slug) do
    trimmed_slug = String.trim(slug)

    if String.starts_with?(trimmed_slug, "/") do
      @mapquest_web_base <> trimmed_slug
    else
      search_url(display)
    end
  end

  def build_url(_, display), do: search_url(display)

  @doc """
  Builds a direct MapQuest search results URL for any address or place string.
  """
  def search_url(query) when is_binary(query) do
    trimmed = String.trim(query)

    if trimmed == "" do
      nil
    else
      "#{@mapquest_web_base}/search/results?query=#{URI.encode_www_form(trimmed)}"
    end
  end

  def search_url(_), do: nil

  @doc """
  Resolves a MapQuest URL for an event's `location` text when saving an event.
  Returns `nil` if `location` is empty or already an `http(s)://` URL (e.g. a Zoom link).
  """
  def resolve_location_url(location, explicit_url \\ nil) do
    trimmed_loc = String.trim(to_string(location || ""))
    trimmed_url = sanitize_url(explicit_url)

    cond do
      trimmed_loc == "" ->
        nil

      Regex.match?(~r/^https?:\/\/\S+/i, trimmed_loc) ->
        nil

      String.starts_with?(trimmed_url, "https://www.mapquest.com/") ->
        trimmed_url

      true ->
        search_url(trimmed_loc)
    end
  end

  @doc """
  Strips RFC 5545 backslash escapes (`\\,`, `\\;`, `\\`) and repairs browser-normalized
  `/,` inside coordinate pairs on MapQuest URLs.
  """
  def sanitize_url(nil), do: ""

  def sanitize_url(url) when is_binary(url) do
    url
    |> String.trim()
    |> String.replace("\\,", ",")
    |> String.replace("\\;", ";")
    |> String.replace("\\", "")
    |> then(fn s -> Regex.replace(~r/(\d)\/,(-?\d)/, s, "\\1,\\2") end)
  end

  def sanitize_url(other), do: sanitize_url(to_string(other))

  defp get_api_key do
    case Application.get_env(:ukko, :mapquest_api_key) do
      key when is_binary(key) ->
        trimmed = String.trim(key)
        if trimmed == "", do: {:error, :missing_mapquest_api_key}, else: {:ok, trimmed}

      _ ->
        {:error, :missing_mapquest_api_key}
    end
  end
end
