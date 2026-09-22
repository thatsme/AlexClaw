defmodule AlexClaw.Scenarios do
  @moduledoc """
  End-to-end checks of what AlexClaw is for, run against a live instance: each
  scenario builds what a user would build, runs it, asserts on what the user
  would see, and removes what it built (a run record is kept as evidence).

      bin/alex_claw rpc 'AlexClaw.Scenarios.run(:rss_digest)'

  Real mode uses the instance's own providers, feeds and gateways. The test
  suite drives the same scenarios in mock mode, with the external systems —
  feeds, LLM provider, gateway — replaced at their boundary.
  """

  @scenarios %{rss_digest: AlexClaw.Scenarios.RssDigest}

  @type verdict :: :pass | {:fail, String.t()}
  @type report :: %{scenario: atom(), verdict: verdict(), details: map()}

  @doc "The scenarios that can be run."
  @spec names() :: [atom()]
  def names, do: Map.keys(@scenarios)

  @doc "Run one scenario and print its report. Answers the report."
  @spec run(atom(), keyword()) :: report()
  def run(name, opts \\ []) do
    report = Map.fetch!(@scenarios, name).run(opts)
    IO.puts(format(report))
    report
  end

  @doc "A report as text: the verdict, then each detail on a line."
  @spec format(report()) :: String.t()
  def format(%{scenario: name, verdict: verdict, details: details}) do
    lines =
      Enum.map(details, fn {key, value} -> "  #{key}: #{inspect(value, printable_limit: 400)}" end)

    Enum.join(["#{name}: #{verdict_text(verdict)}" | lines], "\n")
  end

  defp verdict_text(:pass), do: "PASS"
  defp verdict_text({:fail, reason}), do: "FAIL — #{reason}"
end
