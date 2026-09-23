defmodule AlexClaw.Webhooks.GitHubEvent do
  @moduledoc """
  A verified GitHub webhook event: what a review workflow is asked to review.

  Built only by `AlexClawWeb.GitHubWebhookController`, after the HMAC check, and
  passed as the run's input. It is recognised by its type, never by its shape:
  JSON decoding cannot produce a struct, so a previous step's output cannot pose
  as an event and point the instance's token at another repository.
  """

  @type t :: %__MODULE__{
          event: :pull_request | :push,
          repo: String.t(),
          pr_number: pos_integer() | nil,
          commit_sha: String.t() | nil
        }

  defstruct [:event, :repo, :pr_number, :commit_sha]
end
