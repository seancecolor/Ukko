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
    delete "/events/:uid", EventController, :delete
  end

  scope "/", UkkoWeb do
    pipe_through :browser

    get "/", PageController, :index
  end
end
