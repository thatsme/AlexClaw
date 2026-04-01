defmodule AlexClaw.Reasoning do
  @moduledoc "Context for managing reasoning loop sessions and steps."

  import Ecto.Query
  alias AlexClaw.Repo
  alias AlexClaw.Reasoning.{Session, Step}

  # --- Sessions ---

  @spec list_sessions() :: [Session.t()]
  def list_sessions do
    Session
    |> order_by(desc: :inserted_at)
    |> Repo.all()
  end

  @spec list_sessions_by_status(String.t() | [String.t()]) :: [Session.t()]
  def list_sessions_by_status(status) when is_binary(status) do
    list_sessions_by_status([status])
  end

  def list_sessions_by_status(statuses) when is_list(statuses) do
    Session
    |> where([s], s.status in ^statuses)
    |> order_by(desc: :inserted_at)
    |> Repo.all()
  end

  @spec get_session(integer()) :: {:ok, Session.t()} | {:error, :not_found}
  def get_session(id) do
    case Repo.get(Session, id) do
      nil -> {:error, :not_found}
      session -> {:ok, Repo.preload(session, :steps)}
    end
  end

  @spec active_session() :: Session.t() | nil
  def active_session do
    active_statuses = ~w(planning executing evaluating deciding waiting_user)

    Session
    |> where([s], s.status in ^active_statuses)
    |> order_by(desc: :started_at)
    |> limit(1)
    |> Repo.one()
  end

  @spec create_session(map()) :: {:ok, Session.t()} | {:error, Ecto.Changeset.t()}
  def create_session(attrs) do
    %Session{}
    |> Session.changeset(attrs)
    |> Repo.insert()
  end

  @spec update_session(Session.t(), map()) :: {:ok, Session.t()} | {:error, Ecto.Changeset.t()}
  def update_session(%Session{} = session, attrs) do
    session
    |> Session.changeset(attrs)
    |> Repo.update()
  end

  @spec delete_session(Session.t()) :: {:ok, Session.t()} | {:error, Ecto.Changeset.t()}
  def delete_session(%Session{} = session) do
    Repo.delete(session)
  end

  @spec mark_completed(Session.t(), String.t(), float()) :: {:ok, Session.t()} | {:error, Ecto.Changeset.t()}
  def mark_completed(%Session{} = session, result, confidence) do
    update_session(session, %{
      status: "completed",
      result: result,
      confidence: confidence,
      completed_at: DateTime.utc_now() |> DateTime.truncate(:second)
    })
  end

  @spec mark_failed(Session.t(), String.t()) :: {:ok, Session.t()} | {:error, Ecto.Changeset.t()}
  def mark_failed(%Session{} = session, error) do
    update_session(session, %{
      status: "failed",
      error: error,
      completed_at: DateTime.utc_now() |> DateTime.truncate(:second)
    })
  end

  @spec mark_aborted(Session.t()) :: {:ok, Session.t()} | {:error, Ecto.Changeset.t()}
  def mark_aborted(%Session{} = session) do
    update_session(session, %{
      status: "aborted",
      completed_at: DateTime.utc_now() |> DateTime.truncate(:second)
    })
  end

  @spec mark_stuck(Session.t(), String.t()) :: {:ok, Session.t()} | {:error, Ecto.Changeset.t()}
  def mark_stuck(%Session{} = session, reason) do
    update_session(session, %{
      status: "stuck",
      error: reason,
      completed_at: DateTime.utc_now() |> DateTime.truncate(:second)
    })
  end

  @spec increment_iteration(Session.t()) :: {:ok, Session.t()} | {:error, Ecto.Changeset.t()}
  def increment_iteration(%Session{} = session) do
    update_session(session, %{iteration_count: session.iteration_count + 1})
  end

  @spec increment_llm_calls(Session.t()) :: {:ok, Session.t()} | {:error, Ecto.Changeset.t()}
  def increment_llm_calls(%Session{} = session) do
    update_session(session, %{total_llm_calls: session.total_llm_calls + 1})
  end

  # --- Steps ---

  @spec list_steps(integer()) :: [Step.t()]
  def list_steps(session_id) do
    Step
    |> where([s], s.session_id == ^session_id)
    |> order_by(asc: :iteration, asc: :inserted_at)
    |> Repo.all()
  end

  @spec record_step(map()) :: {:ok, Step.t()} | {:error, Ecto.Changeset.t()}
  def record_step(attrs) do
    %Step{}
    |> Step.changeset(attrs)
    |> Repo.insert()
  end

  @spec latest_step(integer()) :: Step.t() | nil
  def latest_step(session_id) do
    Step
    |> where([s], s.session_id == ^session_id)
    |> order_by(desc: :inserted_at)
    |> limit(1)
    |> Repo.one()
  end

  @spec steps_for_iteration(integer(), integer()) :: [Step.t()]
  def steps_for_iteration(session_id, iteration) do
    Step
    |> where([s], s.session_id == ^session_id and s.iteration == ^iteration)
    |> order_by(asc: :inserted_at)
    |> Repo.all()
  end
end
