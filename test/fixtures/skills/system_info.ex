defmodule AlexClaw.Skills.Dynamic.SystemInfo do
  @behaviour AlexClaw.Skill

  @impl true
  def run(%{} = _args) do
    date_time = DateTime.utc_now() |> DateTime.to_string()
    hostname = :os.cmd('hostname') |> to_string() |> String.trim()
    elixir_version = System.version()

    result_string = "UTC Date/Time: #{date_time}, Hostname: #{hostname}, Elixir Version: #{elixir_version}"
    {:ok, result_string, :on_success}
  end

  @impl true
  def description() do
    "Returns current UTC date/time, hostname, and Elixir version."
  end

  @impl true
  def permissions() do
    []
  end

  @impl true
  def version() do
    "1.0.0"
  end

  @impl true
  def routes() do
    [:on_success]
  end
end
