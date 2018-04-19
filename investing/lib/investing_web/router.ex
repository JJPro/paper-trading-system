defmodule InvestingWeb.Router do
  use InvestingWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_flash
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug InvestingWeb.Plugs.SetUser
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/", InvestingWeb do
    pipe_through :browser # Use the default browser stack

    get "/", PageController, :index
    get "/alerts", PageController, :index
    # get "/main", PageController, :main

    resources "/users", UserController
    resources "/assets", AssetController, except: [:new, :edit]

    get "/login", SessionController, :new
    post "/login", SessionController, :create
    delete "/logout", SessionController, :delete


  end

  if Mix.env == :dev do
    forward "/sent_emails", Bamboo.EmailPreviewPlug
  end

  scope "/auth", InvestingWeb do
    pipe_through :browser

    # the request function which is defined by the Ueberauth module
    get "/:provider", AuthController, :request
    get "/:provider/callback", AuthController, :callback
  end

  # Other scopes may use custom stacks.
  # scope "/api", InvestingWeb do
  #   pipe_through :api
  # end
end
