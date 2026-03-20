defmodule AlexClawWeb.Router do
  @moduledoc "Defines all HTTP routes, pipelines, and scope-level authentication for the web interface."

  use Phoenix.Router
  import Phoenix.LiveView.Router

  pipeline :browser do
    plug(:accepts, ["html"])
    plug(:fetch_session)
    plug(:fetch_live_flash)
    plug(:put_root_layout, html: {AlexClawWeb.Layouts, :root})
    plug(:protect_from_forgery)
    plug(:put_secure_browser_headers)
    plug(AlexClawWeb.Plugs.RateLimit)
  end

  pipeline :api do
    plug(:accepts, ["json"])
  end

  pipeline :require_auth do
    plug(AlexClawWeb.Plugs.RequireAuth)
  end

  # Health check — unauthenticated, no session overhead
  scope "/", AlexClawWeb do
    pipe_through(:api)
    get("/health", HealthController, :check)
  end

  scope "/", AlexClawWeb do
    pipe_through(:browser)

    get("/login", AuthController, :login)
    post("/login", AuthController, :authenticate)
    get("/logout", AuthController, :logout)

    get("/auth/google/callback", OAuthCallbackController, :google)
  end

  scope "/", AlexClawWeb do
    pipe_through([:browser, :require_auth])

    live("/", AdminLive.Dashboard)
    live("/chat", AdminLive.Chat)
    live("/skills", AdminLive.Skills)
    live("/scheduler", AdminLive.Scheduler)
    live("/llm", AdminLive.LLM)
    live("/feeds", AdminLive.Feeds)
    live("/resources", AdminLive.Resources)
    live("/workflows", AdminLive.Workflows)
    live("/workflows/:id/runs", AdminLive.WorkflowRuns)
    live("/database", AdminLive.Database)
    live("/config", AdminLive.Config)
    live("/memory", AdminLive.Memory)
    live("/logs", AdminLive.Logs)

    get("/database/download", DatabaseController, :download)
    get("/metrics", MetricsController, :index)
  end

  # Webhook routes (authenticate via HMAC, not session)
  pipeline :webhook do
    plug(:accepts, ["json"])
  end

  scope "/webhooks", AlexClawWeb do
    pipe_through(:webhook)
    post("/github", GitHubWebhookController, :handle)
  end

  if Mix.env() in [:dev, :test] do
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through(:browser)
      live_dashboard("/dashboard", metrics: AlexClawWeb.Telemetry)
    end
  end
end
