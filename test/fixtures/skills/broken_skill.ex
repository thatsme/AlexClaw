defmodule AlexClaw.Skills.Dynamic.BrokenSkill do
  @moduledoc """
  Test skill that always fails. Used to verify circuit breaker behavior.
  Simulates a service that returns HTTP 503 errors.
  """
  @behaviour AlexClaw.Skill

  @impl true
  def version, do: "1.0.0"

  @impl true
  def permissions, do: []

  @impl true
  def description, do: "Always-failing skill for circuit breaker testing"

  @impl true
  def run(_args) do
    {:error, {:http_error, 503, "Service Unavailable"}}
  end
end
