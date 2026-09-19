defmodule AlexClaw.Skills.Dynamic.SystemInfo do
  @moduledoc """
  Example dynamic skill: reports the container's UTC time, hostname and Elixir
  version. Used as a fixture and as a reference for skill authors.
  """
  @behaviour AlexClaw.Skill

  @impl true
  def run(%{} = _args) do
    date_time = DateTime.utc_now() |> DateTime.to_string()
    # :inet.gethostname/0 rather than :os.cmd/1 — this fixture doubles as the
    # reference skill authors copy, and shelling out is the wrong habit to teach.
    {:ok, hostname_charlist} = :inet.gethostname()
    hostname = to_string(hostname_charlist)
    elixir_version = System.version()

    result_string =
      "UTC Date/Time: #{date_time}, Hostname: #{hostname}, Elixir Version: #{elixir_version}"

    {:ok, result_string, :on_success}
  end

  @impl true
  def description do
    "Returns current UTC date/time, hostname, and Elixir version."
  end

  @impl true
  def permissions do
    []
  end

  @impl true
  def version do
    "1.0.0"
  end

  @impl true
  def routes do
    [:on_success]
  end
end
