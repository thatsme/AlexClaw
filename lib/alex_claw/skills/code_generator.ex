defmodule AlexClaw.Skills.CodeGenerator do
  @moduledoc "Shared skill generation logic for Coder skill and Forge UI."

  require Logger

  # Generated run/1 gets one shot at returning; a blocked one is a failed validation.
  @runtime_timeout_ms 10_000

  alias AlexClaw.Auth.SafeExecutor
  alias AlexClaw.Skills.SkillAPI
  alias AlexClaw.Workflows.SkillRegistry

  @system_prompt """
  You are a code generator for AlexClaw, an Elixir/OTP agent.
  Generate a single Elixir module implementing the AlexClaw.Skill behaviour.

  Rules:
  - Module MUST be AlexClaw.Skills.Dynamic.<CamelizedName>
  - MUST have: @behaviour AlexClaw.Skill
  - MUST mark all callbacks with @impl true
  - run/1 receives args map, MUST return {:ok, result_string, :on_success} or {:error, reason}
  - The result MUST be a string
  - MUST implement: description/0, permissions/0 (list only what you need)
  - For external access use AlexClaw.Skills.SkillAPI (alias as SkillAPI)
  - Available permissions: llm, web_read, memory_read, knowledge_read,
    resources_read, gateway_send. Declare only what the skill uses.
  - Do NOT declare web_read together with memory_read, knowledge_read or
    resources_read: reading private data and reaching the network in one skill
    needs a human to approve it, and the skill will not load on its own.
  - If the skill makes HTTP requests (Req.get, Req.post, etc.), you MUST implement: def external, do: true
  - MUST implement step_fields/0 to declare which UI fields the step editor shows:
    - Skills that use LLM: def step_fields, do: [:llm_tier, :llm_model, :prompt_template, :config]
    - Skills that only need config: def step_fields, do: [:config]
    - Skills with no config: def step_fields, do: []
  - SHOULD implement config_hint/0 returning a JSON example string, e.g.: def config_hint, do: ~s|{"city": "Rome"}|
  - SHOULD implement config_scaffold/0 returning a default config map, e.g.: def config_scaffold, do: %{"city" => ""}
  - HTTP via SkillAPI:
    - SkillAPI.http_get(__MODULE__, url, opts) returns {:ok, %Req.Response{status: N, body: data}} or {:error, reason}
    - Match response as: {:ok, %{status: 200, body: body}} — NOT %{"body" => body}
    - Body is AUTO-DECODED: JSON APIs return maps/lists, HTML returns strings. Do NOT call Jason.decode on the body.
    - Error reasons are structs, not strings. Always use inspect/1: {:error, "Failed: \#{inspect(reason)}"}
    - NEVER put query parameters directly in the URL string. ALWAYS use the params: option:
      WRONG: SkillAPI.http_get(__MODULE__, "https://example.com/api?format=%c")
      RIGHT: SkillAPI.http_get(__MODULE__, "https://example.com/api", params: [format: "%c"])
  - Accessing args in run/1 — args is a keyword list, config values are string-keyed maps:
      config = args[:config] || %{}
      city = config["city"]
      input = args[:input]
  - Jason.decode/1 returns STRING keys, never atoms. Always match with strings:
      WRONG: %{"data" => %{temp_C: 20, humidity: 80}}
      RIGHT: %{"data" => %{"temp_C" => "20", "humidity" => "80"}}
  - JSON values from APIs are usually strings, even numbers. Convert with String.to_integer/1 or String.to_float/1 if needed.
  - Return ONLY the code wrapped in ```elixir ... ```, no explanation
  - Check the provided documentation for correct function signatures and return types
  - Erlang modules in docs (e.g. erlang:foo(), os:bar()) are called in Elixir as :erlang.foo(), :os.bar()
  - Only use modules and functions that exist in the provided documentation. Do NOT invent APIs
  """

  @filler_words ~w(a an the that which returns gets fetches creates makes builds generates is are was were will would should could can do does did have has had been being be for from with into onto upon about above below between through during before after since until of in on at to by and or but not skill skills)

  @spec system_prompt() :: String.t()
  def system_prompt, do: @system_prompt

  @doc "Run one generation iteration: knowledge → prompt → LLM → extract → write → load → validate."
  @spec generate_step(String.t(), String.t(), String.t(), String.t(), String.t() | nil) ::
          {:ok, map()} | {:error, term(), String.t() | nil}
  def generate_step(goal, skill_name, context_source, provider, error_context) do
    kb_context = gather_knowledge(goal, context_source)

    Logger.info(
      "Forge context: #{String.length(kb_context)} chars for goal '#{String.slice(goal, 0, 60)}'"
    )

    prompt = build_prompt(goal, skill_name, kb_context, error_context)
    Logger.info("Forge prompt: #{String.length(prompt)} chars total")

    llm_opts =
      case provider do
        "auto" -> [tier: :local]
        name -> [provider: name]
      end

    case SkillAPI.llm_complete(
           AlexClaw.Skills.Coder,
           prompt,
           Keyword.merge(llm_opts, system: @system_prompt, thinking: false)
         ) do
      {:ok, response} ->
        Logger.info("Forge raw response (first 500 chars): #{String.slice(response, 0, 500)}")

        case extract_code(response) do
          {:ok, code} ->
            try_load(code, skill_name)

          :no_code_block ->
            {:error, :no_code_block, nil}
        end

      {:error, reason} ->
        {:error, {:llm_failed, reason}, nil}
    end
  end

  # Generated code is staged, judged, and only then loaded. It never reaches the
  # live directory on the strength of having compiled, and it never takes over a
  # name that belongs to anything but another generated skill.
  @spec try_load(String.t(), String.t()) :: {:ok, map()} | {:error, term(), String.t()}
  defp try_load(code, skill_name) do
    file_name = "#{skill_name}.ex"

    with :ok <- SkillRegistry.generation_may_replace?(skill_name),
         :ok <- SkillRegistry.write_pending(file_name, code) do
      vet_and_load(file_name, skill_name, code)
    else
      {:error, {:would_replace, _owner} = reason} -> {:error, reason, code}
      {:error, reason} -> {:error, {:write_failed, reason}, code}
    end
  end

  defp vet_and_load(file_name, skill_name, code) do
    case SkillRegistry.vet_pending(file_name) do
      {:ok, %{contained: :ok} = vetted} ->
        load_contained(file_name, skill_name, vetted, code)

      {:ok, %{contained: {:error, violations}}} ->
        {:error, {:not_contained, violations}, code}

      {:error, reason} ->
        {:error, {:load_failed, reason}, code}
    end
  end

  # Contained: the code cannot reach anything outside the allowlist, so it loads
  # without a human in the loop.
  defp load_contained(file_name, skill_name, vetted, code) do
    with :ok <- SkillRegistry.promote_pending(file_name),
         {:ok, info} <-
           SkillRegistry.load_skill(file_name, origin: "generated", approval: "containment") do
      confirm_runtime(info, vetted, code, skill_name)
    else
      {:error, reason} -> {:error, {:load_failed, reason}, code}
      :no_pending -> {:error, {:load_failed, :no_pending}, code}
    end
  end

  # Only contained code is ever executed, and then only under SafeExecutor so a
  # generated run/1 that hangs cannot take the caller with it.
  defp confirm_runtime(info, vetted, code, skill_name) do
    case runtime_verdict(info, vetted) do
      :ok -> {:ok, Map.put(skill_summary(info, code), :approval, :containment)}
      {:error, reason} -> revert_load(skill_name, reason, code)
    end
  end

  defp runtime_verdict(%{external: true, module: module}, _vetted), do: validate_structure(module)
  defp runtime_verdict(%{module: module}, _vetted), do: validate_runtime(module)

  defp revert_load(skill_name, reason, code) do
    SkillAPI.unload_skill(AlexClaw.Skills.Coder, skill_name)
    {:error, {:runtime_validation, reason}, code}
  end

  defp skill_summary(info, code) do
    %{
      name: info.name,
      module: info.module,
      permissions: info.permissions,
      routes: info.routes,
      code: code
    }
  end

  # Not contained: the file stays in pending and the violations become the retry
  # hint. If the model cannot get inside the envelope, the caller asks for a code.

  @doc "Gather RAG context from the knowledge base based on the goal."
  @spec gather_knowledge(String.t(), String.t()) :: String.t()
  def gather_knowledge(goal, context_source \\ "both") do
    if context_source == "none" do
      ""
    else
      # Always include skill template and behaviour — these are critical for correct generation
      template_chunks = fetch_by_source(~w(self:skill_template self:skill_behaviour))
      # Real skill examples for pattern reference
      skill_chunks = search_kb(goal, 2, kind: "skill_source", rewrite: true)
      # Goal-relevant docs (hexdocs, guides)
      goal_chunks = search_kb(goal, 3, rewrite: true)
      erlang_chunks = search_kb(goal, 1, kind: "erlang_docs", rewrite: true)
      elixir_chunks = search_kb(goal, 1, kind: "elixir_source", rewrite: true)

      (template_chunks ++ skill_chunks ++ goal_chunks ++ erlang_chunks ++ elixir_chunks)
      |> Enum.uniq_by(& &1.id)
      |> Enum.map_join("\n---\n", & &1.content)
    end
  end

  @doc "Extract Elixir code from a fenced code block in LLM response."
  @spec extract_code(String.t()) :: {:ok, String.t()} | :no_code_block
  def extract_code(response) do
    # Strip Qwen3-style <think>...</think> blocks before extracting code
    cleaned = Regex.replace(~r/<think>.*?<\/think>/s, response, "")

    case Regex.run(~r/```elixir\s*\n(.*?)```/s, cleaned) do
      [_, code] ->
        {:ok, String.trim(code)}

      nil ->
        case Regex.run(~r/```\s*\n(.*?)```/s, cleaned) do
          [_, code] -> {:ok, String.trim(code)}
          nil -> :no_code_block
        end
    end
  end

  @doc "Derive a snake_case skill name from a natural language goal."
  @spec derive_skill_name(String.t()) :: String.t()
  def derive_skill_name(goal) do
    name =
      goal
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9\s]/, "")
      |> String.split()
      |> Enum.reject(&(&1 in @filler_words))
      |> Enum.take(4)
      |> Enum.join("_")
      |> String.slice(0, 40)

    if name == "", do: "generated_skill", else: name
  end

  @doc "Build the LLM prompt with goal, module name, KB context, and optional error context."
  @spec build_prompt(String.t(), String.t(), String.t(), String.t() | nil) :: String.t()
  def build_prompt(goal, skill_name, kb_context, error_context \\ nil) do
    module_name = Macro.camelize(skill_name)

    context_section =
      if kb_context != "" do
        "\n\nRelevant context from knowledge base:\n#{kb_context}"
      else
        ""
      end

    error_section =
      if error_context do
        "\n\n#{error_context}"
      else
        ""
      end

    """
    Generate a skill called AlexClaw.Skills.Dynamic.#{module_name} that does the following:

    #{goal}
    #{context_section}#{error_section}
    Remember: module name must be AlexClaw.Skills.Dynamic.#{module_name}
    """
  end

  @doc "Validate that an external skill has the required callbacks without executing it."
  @spec validate_structure(module()) :: :ok | {:error, term()}
  def validate_structure(module) do
    Code.ensure_loaded(module)

    cond do
      not function_exported?(module, :run, 1) ->
        {:error, {:missing_callback, "run/1 is not defined"}}

      not function_exported?(module, :description, 0) ->
        {:error, {:missing_callback, "description/0 is not defined"}}

      not function_exported?(module, :permissions, 0) ->
        {:error, {:missing_callback, "permissions/0 is not defined"}}

      true ->
        :ok
    end
  end

  @doc """
  Validate that a loaded skill module runs correctly with test input.

  Runs through `SafeExecutor` rather than calling `run/1` directly: a generated
  `run/1` that blocks would otherwise hang the caller, and there is no reason to
  give generated code the caller's process.

  Only ever called on code that `CallPolicy` has already found contained.
  """
  @spec validate_runtime(module()) :: :ok | {:error, term()}
  def validate_runtime(module) do
    module
    |> SafeExecutor.run(%{input: "test", config: %{}}, :dynamic, nil,
      timeout: @runtime_timeout_ms
    )
    |> runtime_result()
  rescue
    e -> {:error, {:runtime_crash, Exception.message(e)}}
  catch
    kind, reason -> {:error, {:runtime_crash, "#{kind}: #{inspect(reason)}"}}
  end

  defp runtime_result({:ok, result, _branch}) when is_binary(result), do: :ok

  defp runtime_result({:ok, result, _branch}),
    do: {:error, {:runtime_bad_result, "run/1 returned non-string result: #{inspect(result)}"}}

  defp runtime_result({:ok, _}),
    do: {:error, {:runtime_bad_result, "run/1 must return {:ok, string, :branch}, got 2-tuple"}}

  defp runtime_result({:error, :skill_timeout}),
    do: {:error, {:runtime_timeout, "run/1 did not return within #{@runtime_timeout_ms}ms"}}

  defp runtime_result({:error, reason}),
    do: {:error, {:runtime_error_returned, "run/1 returned {:error, #{inspect(reason)}}"}}

  defp runtime_result(other),
    do: {:error, {:runtime_bad_result, "run/1 returned unexpected: #{inspect(other)}"}}

  @doc "Format an error into a hint string for the next LLM iteration."
  @spec error_to_hint(term()) :: String.t()
  def error_to_hint(:no_code_block), do: "You must wrap the code in ```elixir ... ```. Try again."

  def error_to_hint({:load_failed, reason}),
    do: "The previous code had this error: #{inspect(reason)}\nFix the code and try again."

  def error_to_hint({:runtime_validation, reason}),
    do: "The code compiled but failed at runtime: #{inspect(reason)}\nFix the code and try again."

  # The violations are the most useful hint the model gets: they name exactly which
  # calls to replace, and the envelope is small enough to describe in the retry.
  def error_to_hint({:not_contained, violations}) do
    """
    The code called modules a generated skill may not use:
    #{Enum.map_join(violations, "\n", &"  - #{&1}")}

    Rewrite it using SkillAPI instead. SkillAPI.http_get/3 and http_post/3 for the
    network, SkillAPI.llm_complete/3 for the model, SkillAPI.memory_store/4 and
    knowledge_store/4 for persistence, SkillAPI.send_message/3 for output. Do not
    call File, System, Code, Req or Repo directly.
    """
  end

  def error_to_hint({:would_replace, owner}),
    do: "The name is already taken by #{owner}. Retrying will not change that."

  def error_to_hint({:write_failed, reason}), do: "Failed to write skill file: #{inspect(reason)}"
  def error_to_hint({:llm_failed, reason}), do: "LLM call failed: #{inspect(reason)}"
  def error_to_hint(other), do: "Error: #{inspect(other)}"

  defp fetch_by_source(source_prefixes) do
    import Ecto.Query

    conditions =
      Enum.reduce(source_prefixes, dynamic(false), fn prefix, acc ->
        dynamic([e], ^acc or ilike(e.source, ^"#{prefix}%"))
      end)

    AlexClaw.Repo.all(
      from(e in AlexClaw.Knowledge.Entry,
        where: ^conditions,
        order_by: [asc: e.source, asc: e.id]
      )
    )
  end

  @spec search_kb(String.t(), non_neg_integer(), keyword()) :: [map()]
  defp search_kb(query, limit, opts \\ []) do
    case SkillAPI.knowledge_search(
           AlexClaw.Skills.Coder,
           query,
           Keyword.merge([limit: limit], opts)
         ) do
      {:ok, entries} -> entries
      _ -> []
    end
  end
end
