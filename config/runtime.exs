import Config

# Runtime configuration for Ukko (dev & prod)
config :ukko,
  thundermail_caldav_url: System.get_env("THUNDERMAIL_CALDAV_URL"),
  thundermail_carddav_url: System.get_env("THUNDERMAIL_CARDDAV_URL"),
  thundermail_user: System.get_env("THUNDERMAIL_USER"),
  thundermail_pass: System.get_env("THUNDERMAIL_PASS"),
  zoom_account_id: System.get_env("ZOOM_ACCOUNT_ID"),
  zoom_client_id: System.get_env("ZOOM_CLIENT_ID"),
  zoom_client_secret: System.get_env("ZOOM_CLIENT_SECRET"),
  mapquest_api_key: System.get_env("MAPQUEST_API_KEY") || "qnBoTBAt8yIBYNHA3CEV4XMBskNGR94D",
  ukko_passcode: System.get_env("UKKO_PASSCODE")

if System.get_env("PHX_SERVER") do
  config :ukko, UkkoWeb.Endpoint, server: true
end

if config_env() == :prod do
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      You can generate one by calling: mix phx.gen.secret
      """

  host = System.get_env("PHX_HOST") || System.get_env("RAILWAY_PUBLIC_DOMAIN") || "localhost"
  port = String.to_integer(System.get_env("PORT") || "4000")

  config :ukko, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

  config :ukko, UkkoWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    http: [
      ip: {0, 0, 0, 0, 0, 0, 0, 0},
      port: port
    ],
    secret_key_base: secret_key_base,
    server: true,
    check_origin: false
end

