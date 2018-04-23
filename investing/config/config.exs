# This file is responsible for configuring your application
# and its dependencies with the aid of the Mix.Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.
use Mix.Config

# General application configuration
config :investing,
  ecto_repos: [Investing.Repo]

# Configures the endpoint
config :investing, InvestingWeb.Endpoint,
  url: [host: "localhost"],
  secret_key_base: "04zSxpHSF07JWCDAVrFevViGZMO4SJlwbwNHjW9Npk9HEtkul5bfbzs31PDe2gYt",
  render_errors: [view: InvestingWeb.ErrorView, accepts: ~w(html json)],
  pubsub: [name: Investing.PubSub,
           adapter: Phoenix.PubSub.PG2]

# Configures Elixir's Logger
config :logger, :console,
  format: "$time $metadata[$level] $message\n",
  metadata: [:user_id]

config :investing, Investing.Mailer,
  adapter: Bamboo.SendgridAdapter,
  api_key: "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"


# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{Mix.env}.exs"


# Add GitHub to your Überauth configuration
config :ueberauth, Ueberauth,
  # providers are who can user authenticate with for our application
  providers: [
    github: { Ueberauth.Strategy.Github, []}
  ]


# Update your provider configuration
config :ueberauth, Ueberauth.Strategy.Github.OAuth,
  client_id: "94ce5989e1edc92d15d6",
  client_secret: "d14b8d8c4dcec7aa00b5de08aa32bfcd08e5faf3"
