defmodule Ukko.Zoom do
  @moduledoc """
  Zoom Server-to-Server OAuth and Meeting creation/update/cancellation client using `Req`.
  """

  require Logger
  alias Ukko.ZoomTokenCache

  @oauth_url "https://zoom.us/oauth/token"
  @meetings_url "https://api.zoom.us/v2/users/me/meetings"
  @meeting_base_url "https://api.zoom.us/v2/meetings"
  @default_timezone "America/Los_Angeles"

  @doc """
  Creates a Zoom meeting and returns `{:ok, %{join_url: ..., id: ..., password: ...}}`.
  """
  def create_meeting(attrs) do
    do_create_meeting(attrs, true)
  end

  defp do_create_meeting(attrs, allow_retry) do
    with {:ok, token} <- get_access_token() do
      topic = Map.get(attrs, :title) || "Meeting"
      description = Map.get(attrs, :description) || ""
      start_iso = Map.get(attrs, :start)
      end_iso = Map.get(attrs, :end)
      tz = resolve_timezone(Map.get(attrs, :timezone))

      {start_time_utc, duration_minutes} = parse_time_and_duration(start_iso, end_iso)

      payload = %{
        topic: topic,
        type: 2,
        start_time: start_time_utc,
        duration: duration_minutes,
        timezone: tz,
        agenda: String.slice(description, 0, 2000)
      }

      case Req.post(@meetings_url,
             auth: {:bearer, token},
             json: payload
           ) do
        {:ok, %Req.Response{status: status, body: body}} when status in [200, 201] ->
          {:ok,
           %{
             join_url: body["join_url"],
             id: body["id"],
             password: body["password"]
           }}

        {:ok, %Req.Response{status: status, body: body}}
        when allow_retry and status in [400, 401, 403] ->
          if token_or_scope_error?(status, body) do
            ZoomTokenCache.clear()
            do_create_meeting(attrs, false)
          else
            {:error, {:zoom_api_error, status, body}}
          end

        {:ok, %Req.Response{status: status, body: body}} ->
          {:error, {:zoom_api_error, status, body}}

        {:error, exception} ->
          {:error, exception}
      end
    end
  end

  @doc """
  Updates an existing Zoom meeting's `topic`, `start_time`, `duration`, and `timezone` via
  `PATCH /v2/meetings/:meeting_id` when the attached calendar event is moved or edited.
  Automatically clears the cached OAuth token and retries once if scopes were recently updated.
  """
  def update_meeting(meeting_id, attrs) when is_binary(meeting_id) or is_integer(meeting_id) do
    clean_id = meeting_id |> to_string() |> String.replace(~r/[^\d]/, "")

    if clean_id == "" do
      {:error, :invalid_meeting_id}
    else
      do_update_meeting(clean_id, attrs, true)
    end
  end

  defp do_update_meeting(clean_id, attrs, allow_retry) do
    with {:ok, token} <- get_access_token() do
      topic = Map.get(attrs, :title) || "Meeting"
      start_iso = Map.get(attrs, :start)
      end_iso = Map.get(attrs, :end)
      tz = resolve_timezone(Map.get(attrs, :timezone))

      {start_time_utc, duration_minutes} = parse_time_and_duration(start_iso, end_iso)

      payload = %{
        topic: topic,
        type: 2,
        start_time: start_time_utc,
        duration: duration_minutes,
        timezone: tz
      }

      url = "#{@meeting_base_url}/#{clean_id}"

      case Req.patch(url,
             auth: {:bearer, token},
             json: payload
           ) do
        {:ok, %Req.Response{status: status}} when status in [200, 204] ->
          {:ok, clean_id}

        {:ok, %Req.Response{status: status, body: body}}
        when allow_retry and status in [400, 401, 403] ->
          if token_or_scope_error?(status, body) do
            ZoomTokenCache.clear()
            do_update_meeting(clean_id, attrs, false)
          else
            Logger.warning("Zoom PATCH /meetings/#{clean_id} failed (#{status}): #{inspect(body)}")
            {:error, {:zoom_api_error, status, body}}
          end

        {:ok, %Req.Response{status: status, body: body}} ->
          Logger.warning("Zoom PATCH /meetings/#{clean_id} failed (#{status}): #{inspect(body)}")
          {:error, {:zoom_api_error, status, body}}

        {:error, exception} ->
          Logger.warning("Zoom PATCH /meetings/#{clean_id} network error: #{inspect(exception)}")
          {:error, exception}
      end
    end
  end

  @doc """
  Deletes/cancels an existing Zoom meeting via `DELETE /v2/meetings/:meeting_id`.
  """
  def delete_meeting(meeting_id) when is_binary(meeting_id) or is_integer(meeting_id) do
    clean_id = meeting_id |> to_string() |> String.replace(~r/[^\d]/, "")

    if clean_id == "" do
      {:error, :invalid_meeting_id}
    else
      do_delete_meeting(clean_id, true)
    end
  end

  defp do_delete_meeting(clean_id, allow_retry) do
    with {:ok, token} <- get_access_token() do
      url = "#{@meeting_base_url}/#{clean_id}"

      case Req.delete(url,
             auth: {:bearer, token},
             params: [schedule_for_reminder: true]
           ) do
        {:ok, %Req.Response{status: status}} when status in [200, 204, 404] ->
          :ok

        {:ok, %Req.Response{status: status, body: body}}
        when allow_retry and status in [400, 401, 403] ->
          if token_or_scope_error?(status, body) do
            ZoomTokenCache.clear()
            do_delete_meeting(clean_id, false)
          else
            Logger.warning("Zoom DELETE /meetings/#{clean_id} failed (#{status}): #{inspect(body)}")
            {:error, {:zoom_api_error, status, body}}
          end

        {:ok, %Req.Response{status: status, body: body}} ->
          Logger.warning("Zoom DELETE /meetings/#{clean_id} failed (#{status}): #{inspect(body)}")
          {:error, {:zoom_api_error, status, body}}

        {:error, exception} ->
          {:error, exception}
      end
    end
  end

  @doc """
  Formats a Zoom API error into a clear user-facing explanation (especially missing OAuth scopes).
  """
  def format_error({:zoom_api_error, _status, %{"code" => 4711, "message" => msg}}) do
    "Calendar event was moved, but Zoom rejected updating the meeting time (#{msg}). Enable the 'meeting:update:meeting:admin' (and 'meeting:delete:meeting:admin') scopes on your Zoom Server-to-Server OAuth app at marketplace.zoom.us."
  end

  def format_error({:zoom_api_error, status, %{"message" => msg}}) do
    "Calendar event was saved, but Zoom returned HTTP #{status}: #{msg}"
  end

  def format_error({:zoom_api_error, status, body}) do
    "Calendar event was saved, but Zoom returned HTTP #{status}: #{inspect(body)}"
  end

  def format_error(:missing_zoom_credentials) do
    "Calendar event was saved, but Zoom credentials are not configured."
  end

  def format_error(other) do
    "Calendar event was saved, but Zoom meeting sync failed: #{inspect(other)}"
  end

  defp token_or_scope_error?(401, _body), do: true
  defp token_or_scope_error?(_status, %{"code" => code}) when code in [124, 4700, 4711], do: true
  defp token_or_scope_error?(_, _), do: false

  defp resolve_timezone(tz) when is_binary(tz) do
    trimmed = String.trim(tz)
    if trimmed == "" or String.upcase(trimmed) == "UTC", do: @default_timezone, else: trimmed
  end

  defp resolve_timezone(_), do: @default_timezone

  @doc """
  Extracts a Zoom numeric Meeting ID from an event's `location` or `description`
  (matching either `Meeting ID: 1234567890` or a `https://...zoom.us/j/1234567890` URL).
  Returns `nil` if no Zoom meeting is attached.
  """
  def extract_meeting_id(location, description) do
    loc_str = to_string(location || "")
    desc_str = to_string(description || "")
    combined = loc_str <> "\n" <> desc_str

    cond do
      match = Regex.run(~r/zoom\.us\/(?:j|w)\/(\d{9,13})/i, combined, capture: :all_but_first) ->
        List.first(match)

      match =
          Regex.run(~r/Meeting\s+ID:\s*([0-9][0-9\s-]{7,16}[0-9])/i, desc_str,
            capture: :all_but_first
          ) ->
        match
        |> List.first()
        |> String.replace(~r/[^\d]/, "")

      true ->
        nil
    end
  end

  @doc """
  Gets a cached Zoom OAuth access token or fetches a new one via Server-to-Server OAuth.
  """
  def get_access_token do
    ZoomTokenCache.get_or_fetch(&fetch_access_token/0)
  end

  def fetch_access_token do
    account_id = config(:zoom_account_id)
    client_id = config(:zoom_client_id)
    client_secret = config(:zoom_client_secret)

    if is_nil(account_id) or is_nil(client_id) or is_nil(client_secret) do
      {:error, :missing_zoom_credentials}
    else
      case Req.post(@oauth_url,
             auth: {:basic, "#{client_id}:#{client_secret}"},
             params: [grant_type: "account_credentials", account_id: account_id]
           ) do
        {:ok, %Req.Response{status: 200, body: %{"access_token" => token} = body}} ->
          expires_in = Map.get(body, "expires_in", 3600)
          {:ok, token, expires_in}

        {:ok, %Req.Response{status: status, body: body}} ->
          {:error, {:zoom_oauth_error, status, body}}

        {:error, exception} ->
          {:error, exception}
      end
    end
  end

  @doc """
  Appends Zoom meeting details to an event description.
  """
  def append_meeting_details(description, %{join_url: join_url, id: id, password: password}) do
    base = String.trim(description || "")

    zoom_block =
      [
        "--- Zoom Meeting ---",
        "Join URL: #{join_url}",
        if(id, do: "Meeting ID: #{id}", else: nil),
        if(password && password != "", do: "Passcode: #{password}", else: nil)
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.join("\n")

    if base == "" do
      zoom_block
    else
      base <> "\n\n" <> zoom_block
    end
  end

  defp parse_time_and_duration(start_iso, end_iso) do
    start_dt = parse_datetime(start_iso) || DateTime.utc_now()
    end_dt = parse_datetime(end_iso)

    duration =
      if end_dt do
        diff_min = div(DateTime.diff(end_dt, start_dt, :second), 60)
        if diff_min > 0, do: diff_min, else: 30
      else
        30
      end

    start_str =
      start_dt
      |> DateTime.shift_zone!("Etc/UTC")
      |> DateTime.truncate(:second)
      |> DateTime.to_iso8601()

    {start_str, duration}
  end

  defp parse_datetime(nil), do: nil

  defp parse_datetime(iso) when is_binary(iso) do
    trimmed = String.trim(iso)

    cond do
      match?({:ok, _, _}, DateTime.from_iso8601(trimmed)) ->
        {:ok, dt, _} = DateTime.from_iso8601(trimmed)
        dt

      match?({:ok, _}, NaiveDateTime.from_iso8601(trimmed)) ->
        {:ok, ndt} = NaiveDateTime.from_iso8601(trimmed)
        DateTime.from_naive!(ndt, "Etc/UTC")

      match?({:ok, _}, NaiveDateTime.from_iso8601(trimmed <> ":00")) ->
        {:ok, ndt} = NaiveDateTime.from_iso8601(trimmed <> ":00")
        DateTime.from_naive!(ndt, "Etc/UTC")

      match?({:ok, _}, Date.from_iso8601(trimmed)) ->
        {:ok, d} = Date.from_iso8601(trimmed)
        DateTime.new!(d, ~T[09:00:00], "Etc/UTC")

      true ->
        nil
    end
  end

  defp config(key) do
    Application.get_env(:ukko, key)
  end
end
