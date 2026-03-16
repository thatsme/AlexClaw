defmodule AlexClaw.Scheduler do
  @moduledoc """
  Autonomous trigger system. Fires skills on schedule without user input.
  Uses Quantum for cron expressions.
  """
  use Quantum, otp_app: :alex_claw
end
