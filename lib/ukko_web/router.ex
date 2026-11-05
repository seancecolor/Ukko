defmodule UkkoWeb.Router do
  use UkkoWeb, :router

  pipeline :api do
    plug :accepts, ["json"]
  end

  pipeline :browser do
    plug :accepts, ["html"]
  end

  scope "/api", UkkoWeb do
    pipe_through :api

    get "/health", HealthController, :index
  end

  scope "/", UkkoWeb do
    pipe_through :browser

    get "/", PageController, :index
  end
end

