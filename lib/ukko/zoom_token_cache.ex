defmodule Ukko.ZoomTokenCache do
  @moduledoc """
  Caches the Zoom Server-to-Server OAuth access token until its `expires_in` timestamp.
  """
  use Agent

  def start_link(_opts) do
    Agent.start_link(fn -> nil end, name: __MODULE__)
  end

  @doc """
  Returns `{:ok, access_token}` from cache if valid (with a 60-second safety margin),
  otherwise calls `fetcher.()` which should return `{:ok, access_token, expires_in}`.
  """
  def get_or_fetch(fetcher) when is_function(fetcher, 0) do
    now = System.system_time(:second)

    case Agent.get(__MODULE__, & &1) do
      %{access_token: token, expires_at: expires_at} when is_binary(token) and expires_at > now + 60 ->
        {:ok, token}

      _ ->
        case fetcher.() do
          {:ok, token, expires_in} ->
            expires_at = System.system_time(:second) + expires_in
            Agent.update(__MODULE__, fn _ -> %{access_token: token, expires_at: expires_at} end)
            {:ok, token}

          {:error, _reason} = error ->
            error
        end
    end
  end

  def clear do
    Agent.update(__MODULE__, fn _ -> nil end)
  end
end
