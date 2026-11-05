import Config

config :ukko,
  generators: [timestamp_type: :utc_datetime]

config :ukko, UkkoWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [json: UkkoWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: Ukko.PubSub,
  live_view: [signing_salt: "ukko_live_view_salt"]

config :logger, :console,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

config :phoenix, :json_library, Jason

import_config "#{config_env()}.exs"

