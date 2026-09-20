defmodule AlexClaw.Auth.Principal do
  @moduledoc """
  Whose authority an action ran under.

  Distinct from the caller. "A dynamic skill" and "an admin session" say what
  made the call; the principal says on whose behalf it was allowed, and those
  are the same only while there is exactly one person.

  There is exactly one person: `owner`. This exists as a named concept anyway,
  because the alternative is a system whose audit rows answer "who approved
  this" only by the fact that there has never been anyone else — which stops
  being an answer the moment there is. Adding it later would also mean
  inventing a value for every row already written.

  Requests and approvals are recorded separately, since the interesting case
  the day there is more than one principal is the one where they differ.
  """

  @owner "owner"

  @doc "The principal every action currently runs under."
  @spec current() :: String.t()
  def current, do: @owner

  @doc "The principal that asked for an action."
  @spec requested_by() :: String.t()
  def requested_by, do: current()

  @doc """
  The principal that approved an action.

  Today this is the same as the requester, because the same person does both.
  Four-eyes approval would be exactly the case where it is not, and the field
  is what makes that a change rather than a migration.
  """
  @spec approved_by() :: String.t()
  def approved_by, do: current()

  @doc "The principal fields to record alongside an audit row."
  @spec audit_fields() :: %{
          principal: String.t(),
          requested_by: String.t(),
          approved_by: String.t()
        }
  def audit_fields do
    %{principal: current(), requested_by: requested_by(), approved_by: approved_by()}
  end
end
