defmodule UkkoWeb.Router do
  use UkkoWeb, :router

  pipeline :api do
    plug :accepts, ["json"]
    plug :fetch_session
  end

  pipeline :api_auth do
    plug UkkoWeb.Plugs.RequireAuth
  end

  pipeline :browser do
    plug :accepts, ["html"]
  end

  scope "/api", UkkoWeb do
    pipe_through :api

    get "/health", HealthController, :index
    post "/auth", AuthController, :create
  end

  scope "/api", UkkoWeb do
    pipe_through [:api, :api_auth]

    get "/events", EventController, :index
    post "/events", EventController, :create
    post "/events/import", EventController, :import_ics
    put "/events/:uid", EventController, :update
    delete "/events/:uid", EventController, :delete

    get "/subscriptions", EventController, :list_subscriptions
    post "/subscriptions", EventController, :create_subscription
    put "/subscriptions/:id", EventController, :update_subscription
    delete "/subscriptions/:id", EventController, :delete_subscription
  end

  scope "/", UkkoWeb do
    pipe_through :browser

    get "/", PageController, :index
  end
end
