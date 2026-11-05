defmodule Ukko.Zoom do
  @moduledoc """
  Zoom Server-to-Server OAuth and Meeting creation client using `Req`.
  """

  alias Ukko.ZoomTokenCache

  @oauth_url "https://zoom.us/oauth/token"
  @meetings_url "https://api.zoom.us/v2/users/me/meetings"

  @doc """
  Creates a Zoom meeting and returns `{:ok, %{join_url: ..., id: ..., password: ...}}`.
  """
  def create_meeting(attrs) do
    with {:ok, token} <- get_access_token() do
      topic = Map.get(attrs, :title) || "Meeting"
      description = Map.get(attrs, :description) || ""
      start_iso = Map.get(attrs, :start)
      end_iso = Map.get(attrs, :end)

      {start_time_utc, duration_minutes} = parse_time_and_duration(start_iso, end_iso)

      payload = %{
        topic: topic,
        type: 2,
        start_time: start_time_utc,
        duration: duration_minutes,
        timezone: "UTC",
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

        {:ok, %Req.Response{status: status, body: body}} ->
          {:error, {:zoom_api_error, status, body}}

        {:error, exception} ->
          {:error, exception}
      end
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
