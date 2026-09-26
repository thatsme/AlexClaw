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
    post("/logout", AuthController, :logout)
  end

  scope "/", AlexClawWeb do
    pipe_through([:browser, :require_auth])

    # Every page mounts through RequireSession, which asks the server whether
    # the login still stands. The plug above covers the first HTTP render; the
    # hook covers the websocket, which never passes through the plug.
    #
    # The app layout is where the flash messages render. Without it every page's
    # put_flash was set and never shown.
    live_session :authenticated,
      on_mount: AlexClawWeb.Live.RequireSession,
      layout: {AlexClawWeb.Layouts, :app} do
      live("/", AdminLive.Dashboard)
      live("/chat", AdminLive.Chat)
      live("/forge", AdminLive.Forge)
      live("/skills", AdminLive.Skills)
      live("/scheduler", AdminLive.Scheduler)
      live("/llm", AdminLive.LLM)
      live("/resources", AdminLive.Resources)
      live("/workflows", AdminLive.Workflows)
      live("/workflows/:id/runs", AdminLive.WorkflowRuns)
      live("/database", AdminLive.Database)
      live("/services", AdminLive.Services)
      live("/config", AdminLive.Config)
      live("/memory", AdminLive.Memory)
      live("/logs", AdminLive.Logs)
      live("/policies", AdminLive.Policies)
      live("/cluster", AdminLive.Cluster)
    end

    get("/database/download", DatabaseController, :download)
    get("/database/export", DatabaseController, :export)
    get("/workflows/:id/export", WorkflowExportController, :export)
    # The session that asked for the Google connection redeems it.
    get("/auth/google/callback", OAuthCallbackController, :google)
    get("/metrics", MetricsController, :index)
  end

  # MCP endpoint (Bearer token auth, Streamable HTTP transport)
  pipeline :mcp do
    plug(:accepts, ["json", "text/event-stream"])
    plug(AlexClawWeb.Plugs.McpAuth)
  end

  scope "/mcp" do
    pipe_through(:mcp)
    forward("/", AlexClawWeb.Plugs.McpForward)
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
