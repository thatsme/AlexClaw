defmodule AlexClawWeb.ErrorHTML do
  @moduledoc "Renders plain-text error pages from HTTP status codes."

  use Phoenix.Component

  @spec render(String.t(), map()) :: String.t()
  def render(template, _assigns) do
    Phoenix.Controller.status_message_from_template(template)
  end
end
