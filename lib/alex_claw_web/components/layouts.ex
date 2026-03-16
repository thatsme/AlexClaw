defmodule AlexClawWeb.Layouts do
  @moduledoc "Provides the root and app layout templates for the web interface."

  use Phoenix.Component
  import Phoenix.Controller, only: [get_csrf_token: 0]
  import AlexClawWeb.CoreComponents

  embed_templates "layouts/*"
end
