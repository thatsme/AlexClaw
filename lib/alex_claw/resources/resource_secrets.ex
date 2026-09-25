defmodule AlexClaw.Resources.ResourceSecrets do
  @moduledoc """
  A resource's credential, `metadata["auth"]["value"]`, and a recording's fill
  values (`AlexClaw.WebAutomation.Recording.fields/1`), kept in OpenBao as
  secrets the resource owns (`AlexClaw.Secrets.Owned`); the stored metadata
  holds references. A recording's logins are bound to its origin, as a
  web_automation step's are; the rest of this note is about the credential.

  It is bound to the host a request to the resource goes to, as it was when
  the value was entered: the discovered API base (`metadata["discovery"]
  ["base_url"]`) when there is one, as `api_request` uses it, else the
  resource's `url`. Moving the resource to another host with the credential
  kept is refused. At run time the executor resolves it for that host (`resolved/1`)
  and the skill gets the value; nothing else does.
  """
  alias AlexClaw.Secrets
  alias AlexClaw.Secrets.Owned
  alias AlexClaw.WebAutomation.Recording

  @path ["auth", "value"]

  @doc "The credential fields of `metadata`, as path => value."
  @spec fields(map() | nil) :: %{Owned.path() => term()}
  def fields(%{"auth" => %{"value" => value}}), do: %{@path => value}
  def fields(_metadata), do: %{}

  @doc "The secrets `metadata` references, as path => name."
  @spec references(map() | nil) :: %{Owned.path() => String.t()}
  def references(metadata), do: metadata |> fields() |> Owned.references()

  @doc """
  Plan the credential of a resource being saved from `changeset`, against the
  metadata it held before. Returns the changeset with the reference in place
  of the value, and what to store and delete; or the changeset with an error
  on `metadata`.
  """
  @spec plan(Ecto.Changeset.t(), map() | nil) ::
          {:ok, Ecto.Changeset.t(), Owned.secrets()} | {:error, Ecto.Changeset.t()}
  def plan(%Ecto.Changeset{valid?: false} = changeset, _old_metadata), do: {:error, changeset}

  # Two parts, one save: the credential, bound to the resource's host; a
  # recording's fill values, bound to its origin, like a web_automation step's.
  def plan(changeset, old_metadata) do
    metadata = Ecto.Changeset.get_field(changeset, :metadata) || %{}
    url = Ecto.Changeset.get_field(changeset, :url)
    host = destination(url, metadata)
    origin = Recording.destination(metadata, url)

    with {:ok, auth, auth_dropped} <-
           Owned.plan(
             fields(metadata),
             references(old_metadata),
             host,
             &Owned.name("resource", &1)
           ),
         {:ok, logins, logins_dropped} <-
           Owned.plan(
             Recording.fields(metadata),
             Recording.references(old_metadata),
             origin,
             &Owned.name("recording", &1)
           ) do
      plan = Map.merge(auth, logins)
      metadata = Owned.referenced(metadata, plan)

      {:ok, Ecto.Changeset.put_change(changeset, :metadata, metadata),
       {plan, &part_destination(&1, host, origin), auth_dropped ++ logins_dropped}}
    else
      {:error, reason} -> {:error, Ecto.Changeset.add_error(changeset, :metadata, reason)}
    end
  end

  defp part_destination(["auth" | _], host, _origin), do: host
  defp part_destination(_recording_path, _host, origin), do: origin

  @doc "The destination a resource's credential is bound to: its API base's host, else its URL's."
  @spec destination(String.t() | nil, map() | nil) :: String.t() | nil
  def destination(_url, %{"discovery" => %{"base_url" => base}})
      when is_binary(base) and base != "",
      do: Owned.url_binding(base)

  def destination(url, _metadata), do: Owned.url_binding(url)

  @doc "The kind of secret at `path`: the credential, or a recording's login."
  @spec kind(Owned.path()) :: String.t()
  def kind(["auth" | _]), do: "api_token"
  def kind(_recording_path), do: "login"

  @doc "Delete the secrets the resource references: its credential, and a recording's logins."
  @spec delete(%{metadata: map() | nil}) :: :ok
  def delete(%{metadata: metadata}) do
    Owned.delete(Map.values(references(metadata)) ++ Map.values(Recording.references(metadata)))
  end

  @doc """
  The resource with its credential resolved for the host it is bound to: what
  the executor hands a skill. The use is audited. A credential or a login
  still held as a value (0.3.x, not yet moved by the upgrade) is refused.
  """
  @spec resolved(struct()) :: {:ok, struct()} | {:error, term()}
  def resolved(%{metadata: metadata, url: url} = resource) do
    with :ok <- all_moved(resource, Map.merge(fields(metadata), Recording.fields(metadata))) do
      case references(metadata) do
        map when map == %{} ->
          {:ok, resource}

        %{@path => name} ->
          resource |> resolve(name, destination(url, metadata)) |> with_value(resource)
      end
    end
  end

  defp all_moved(resource, fields), do: moved_for(Owned.all_moved(fields), resource)

  defp moved_for(:ok, _resource), do: :ok

  defp moved_for({:error, _path}, resource),
    do: {:error, {:secret, "resource #{resource.name}", :not_moved}}

  defp resolve(_resource, _name, nil), do: {:error, :no_destination}
  defp resolve(_resource, name, destination), do: Secrets.resolve(name, for: destination)

  defp with_value({:ok, value}, resource),
    do: {:ok, %{resource | metadata: put_in(resource.metadata, @path, value)}}

  defp with_value({:error, reason}, resource),
    do: {:error, {:secret, "resource #{resource.name}", reason}}

  @doc "Every resource in `resources`, resolved (`resolved/1`); the first failure stops."
  @spec resolved_all([struct()] | nil) :: {:ok, [struct()] | nil} | {:error, term()}
  def resolved_all(resources) when is_list(resources) do
    Enum.reduce_while(resources, {:ok, []}, fn resource, {:ok, acc} ->
      case resolved(resource) do
        {:ok, resolved} -> {:cont, {:ok, [resolved | acc]}}
        error -> {:halt, error}
      end
    end)
    |> reversed()
  end

  def resolved_all(resources), do: {:ok, resources}

  defp reversed({:ok, list}), do: {:ok, Enum.reverse(list)}
  defp reversed(error), do: error
end
