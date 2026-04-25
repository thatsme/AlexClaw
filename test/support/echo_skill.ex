defmodule AlexClawTest.Skills.EchoSkill do
  @moduledoc false

  @behaviour AlexClaw.Skill

  @impl true
  def description, do: "Test echo skill — succeeds unless input contains 'fail'"

  @impl true
  def routes, do: [:on_success, :on_error]

  @impl true
  def step_fields, do: []

  @impl true
  def config_hint, do: ""

  @impl true
  def config_scaffold, do: %{}

  @impl true
  def config_help, do: ""

  @impl true
  def prompt_help, do: ""

  @impl true
  def run(args) do
    input = Map.get(args, :input, "")

    cond do
      String.contains?(input, "fail") -> {:error, :echo_failed}
      String.contains?(input, "raise") -> raise "echo skill raised"
      true -> {:ok, "echoed: #{input}"}
    end
  end
end
