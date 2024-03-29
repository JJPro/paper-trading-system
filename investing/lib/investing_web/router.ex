defmodule InvestingWeb.Router do
  use InvestingWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_flash
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug InvestingWeb.Plugs.SetUser
    plug :put_user_token
    plug :put_user_id
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/", InvestingWeb do
    pipe_through :browser # Use the default browser stack

    get "/", PageController, :index
    get "/alerts", PageController, :index
    get "/portfolio", PageController, :index
    # get "/main", PageController, :main

    resources "/users", UserController, except: [:index]

    get "/login", SessionController, :new
    post "/login", SessionController, :create
    get "/logout", SessionController, :delete


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
  scope "/api/v1", InvestingWeb do
    pipe_through :api

    resources "/orders", OrderController, except: [:new, :edit]
    resources "/holdings", HoldingController, except: [:new, :edit]

    resources "/assets", AssetController, only: [:create, :delete, :show]
    get "/assets/user/:token", AssetController, :index
    get "/assets/lookup/:term", AssetController, :lookup

  end

  defp put_user_token(conn, _) do
    if current_user = conn.assigns[:current_user] do
      token = Phoenix.Token.sign(conn, "auth token", current_user.id)
      assign(conn, :user_token, token)
    else
      conn
    end
  end

  defp put_user_id(conn, _) do
    if current_user = conn.assigns[:current_user] do
      assign(conn, :user_id, current_user.id)
    else
      conn
    end
  end

end
