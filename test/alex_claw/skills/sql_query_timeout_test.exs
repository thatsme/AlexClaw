defmodule AlexClaw.Skills.SqlQueryTimeoutTest do
  @moduledoc """
  A `sql_query` step's deadline has a ceiling (reports/SQLREAD_ATTACKER_REVIEW.md
  L1): a query holds its tables' locks, a session of the pool and the
  executor for as long as its deadline, so `timeout_ms` is at most five
  minutes. Checked with the step's config, at save and before every run.
  """
  use ExUnit.Case, async: true
  @moduletag :unit

  alias AlexClaw.Skills.SqlQuery

  defp config(ms), do: %{"connection" => "c", "query" => "SELECT 1 AS n", "timeout_ms" => ms}

  test "five minutes is the most a step may wait" do
    assert :ok = SqlQuery.validate_config(config(300_000))
  end

  test "a longer deadline is refused, naming the maximum" do
    for ms <- [300_001, 2_147_483_647, 10_000_000_000] do
      assert {:error, [reason]} = SqlQuery.validate_config(config(ms))
      assert reason =~ "300000"
    end
  end

  test "a deadline is still a positive number of milliseconds" do
    for ms <- [0, -1, "1000", nil] do
      assert {:error, [_reason]} = SqlQuery.validate_config(config(ms))
    end
  end
end
