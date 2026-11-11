defmodule Ukko.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      UkkoWeb.Telemetry,
      {DNSCluster, query: Application.get_env(:ukko, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Ukko.PubSub},
      Ukko.FastCache,
      Ukko.ZoomTokenCache,
      Ukko.Subscriptions,
      UkkoWeb.Endpoint
    ]

    opts = [strategy: :one_for_one, name: Ukko.Supervisor]
    Supervisor.start_link(children, opts)
  end

  @impl true
  def config_change(changed, _new, removed) do
    UkkoWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
