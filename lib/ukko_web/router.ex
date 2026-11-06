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
    get "/feed/:token/ukko.ics", FeedController, :show
    get "/feed/:token", FeedController, :show
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

    get "/feed-token", EventController, :get_feed_token
    post "/feed-token/rotate", EventController, :rotate_feed_token
    get "/contacts", EventController, :list_contacts
  end

  scope "/", UkkoWeb do
    pipe_through :browser

    get "/", PageController, :index
  end
end
