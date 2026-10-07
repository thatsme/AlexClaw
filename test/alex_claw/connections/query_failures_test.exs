defmodule AlexClaw.Connections.QueryFailuresTest do
  @moduledoc """
  How a query fails (reports/SQLREAD_FIX_REVIEW.md F6, F7).

  - F6: a failure the query's boundary turns into `{:query_failed, kind}` —
    which can only be AlexClaw's own bug once the driver's errors are
    handled — is logged with its kind and where it happened, never its
    message or the arguments in its stack, which can hold values.
  - F7: a numeric parameter beyond PostgreSQL's numeric range is a bad
    parameter, naming its position — never left to the driver.
  """
  use ExUnit.Case, async: true
  @moduletag :unit

  import ExUnit.CaptureLog

  alias AlexClaw.Connections.{Query, Types}

  describe "F6: the boundary logs AlexClaw's own bugs" do
    test "an exception is a stated error, logged by kind and place, never its message" do
      log =
        capture_log(fn ->
          assert {:error, {:query_failed, "ArgumentError"}} =
                   Query.guarded(fn -> raise ArgumentError, "row-value-4711" end)
        end)

      assert log =~ "ArgumentError"
      assert log =~ "query_failures_test.exs"
      refute log =~ "row-value-4711"
    end

    test "the arguments a failed call was given are not logged" do
      log =
        capture_log(fn ->
          assert {:error, {:query_failed, "FunctionClauseError"}} =
                   Query.guarded(fn -> String.trim(%{secret_field: "arg-value-0815"}) end)
        end)

      assert log =~ "FunctionClauseError"
      refute log =~ "arg-value-0815"
    end
  end

  describe "F7: numeric parameters within PostgreSQL's range" do
    for value <- ["1e999999999", "1e-999999", "-1E131073"] do
      test "#{value} is refused" do
        assert {:error, _why} = Types.coerce("numeric", unquote(value))
      end
    end

    test "an integer with more digits than numeric holds is refused" do
      assert {:error, _why} = Types.coerce("numeric", Integer.pow(10, 131_073))
    end

    test "ordinary numbers are accepted" do
      for value <- ["12.50", "-0.001", "1e10", 42, 3.25, "NaN"] do
        assert {:ok, %Decimal{}} = Types.coerce("numeric", value)
      end
    end
  end
end
