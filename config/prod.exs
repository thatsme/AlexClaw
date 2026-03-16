import Config

config :alex_claw, AlexClaw.Repo,
  pool_size: 10

config :alex_claw, AlexClawWeb.Endpoint,
  server: true,
  url: [host: "localhost", port: 5001],
  http: [ip: {0, 0, 0, 0}, port: 5001]

config :logger, level: :info
