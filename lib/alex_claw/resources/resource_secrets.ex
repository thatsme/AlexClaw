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
  kept is refused. At run time the skill gets a placeholder (`for_skill/1`); the
  value is attached at send, in the resource's auth header only, for the host
  the request actually goes to (`AlexClaw.Net.Credentials`), and only for a
  skill that attaches it there (`given_to/2`).
  """
  alias AlexClaw.Secrets.Owned
  alias AlexClaw.WebAutomation.Recording

  @path ["auth", "value"]

  # The skills that attach a resource's secrets in a declared slot: the auth
  # header (api_request), a recording's logins (web_automation).
  @attached_by ~w(api_request web_automation)

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
  What the executor hands a skill: the resource with its credential and its
  recording's logins replaced by placeholders
  (`AlexClaw.Secrets.Owned.placeholder/1`), and the names of those secrets.
  The skill never holds a value: the credential is attached at send, for the
  host the request goes to (`AlexClaw.Net.Credentials`). A credential or a
  login still held as a value (0.3.x, not yet moved by the upgrade) is refused.
  """
  @spec for_skill(struct()) :: {:ok, struct(), [String.t()]} | {:error, term()}
  def for_skill(%{metadata: metadata} = resource) do
    fields = Map.merge(fields(metadata), Recording.fields(metadata))

    with :ok <- all_moved(resource, fields) do
      {given, names} = Owned.with_placeholders(metadata || %{}, fields)
      {:ok, %{resource | metadata: given_metadata(metadata, given)}, names}
    end
  end

  defp given_metadata(nil, _given), do: nil
  defp given_metadata(_metadata, given), do: given

  defp all_moved(resource, fields), do: moved_for(Owned.all_moved(fields), resource)

  defp moved_for(:ok, _resource), do: :ok

  defp moved_for({:error, _path}, resource),
    do: {:error, {:secret, "resource #{resource.name}", :not_moved}}

  @doc """
  The resource secrets `names` a `skill` step may have attached: all of them
  for a skill that attaches them in a declared slot (api_request's auth
  header, web_automation's logins), none for any other (S9 fix review H3).
  """
  @spec given_to(String.t() | nil, [String.t()]) :: [String.t()]
  def given_to(skill, names) when skill in @attached_by, do: names
  def given_to(_skill, _names), do: []

  @doc "Every resource in `resources` as a skill is given it (`for_skill/1`), and all their secret names; the first failure stops."
  @spec for_skill_all([struct()] | nil) ::
          {:ok, [struct()] | nil, [String.t()]} | {:error, term()}
  def for_skill_all(resources) when is_list(resources) do
    resources
    |> Enum.reduce_while({:ok, [], []}, fn resource, {:ok, acc, names} ->
      case for_skill(resource) do
        {:ok, given, more} -> {:cont, {:ok, [given | acc], names ++ more}}
        error -> {:halt, error}
      end
    end)
    |> reversed()
  end

  def for_skill_all(resources), do: {:ok, resources, []}

  defp reversed({:ok, list, names}), do: {:ok, Enum.reverse(list), names}
  defp reversed(error), do: error
end
