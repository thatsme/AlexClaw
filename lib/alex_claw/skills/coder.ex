defmodule AlexClaw.Skills.Coder do
  @moduledoc """
  Autonomous code generation skill. Uses the local LLM to generate
  dynamic skills from natural language goals, then loads them via SkillAPI.
  """
  @behaviour AlexClaw.Skill
  require Logger

  alias AlexClaw.Skills.SkillAPI

  @impl true
  @spec description() :: String.t()
  def description, do: "Generate dynamic skills from natural language goals using local LLM"

  @impl true
  @spec routes() :: [atom()]
  def routes, do: [:on_created, :on_workflow_created, :on_error]

  @impl true
  @spec permissions() :: :all
  def permissions, do: :all

  @default_max_retries 5

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
  - Available permissions: llm, web_read, memory_read, memory_write,
    knowledge_read, knowledge_write, config_read, resources_read,
    skill_invoke, gateway_send
  - Return ONLY the code wrapped in ```elixir ... ```, no explanation
  - Check the provided documentation for correct function signatures and return types
  - Erlang modules in docs (e.g. erlang:foo(), os:bar()) are called in Elixir as :erlang.foo(), :os.bar()
  - Only use modules and functions that exist in the provided documentation. Do NOT invent APIs
  """

  @impl true
  @spec run(map()) :: {:ok, String.t(), atom()} | {:error, any()}
  def run(args) do
    input = args[:input] || args[:config]["goal"] || ""
    config = args[:config] || %{}

    if String.trim(input) == "" do
      {:error, :no_goal}
    else
      max_retries = config["max_retries"] || @default_max_retries
      skill_name = derive_skill_name(input)
      do_generate(input, skill_name, config, max_retries)
    end
  end

  @spec handle(String.t(), keyword()) :: :ok
  def handle(goal, opts \\ []) do
    case run(%{input: goal}) do
      {:ok, result, _branch} ->
        AlexClaw.Gateway.Router.send_message(result, opts)

      {:error, reason} ->
        Logger.warning("Coder failed: #{inspect(reason)}", skill: :coder)
        AlexClaw.Gateway.Router.send_message("Coder failed: #{inspect(reason)}", opts)
    end
  end

  defp do_generate(goal, skill_name, config, max_retries) do
    # Gather context from knowledge base
    kb_context = gather_knowledge(goal)

    # Build initial prompt
    prompt = build_prompt(goal, skill_name, kb_context)

    # Retry loop
    case generation_loop(prompt, skill_name, max_retries, config, nil) do
      {:ok, result} ->
        if config["create_workflow"] do
          case create_skill_workflow(skill_name) do
            {:ok, workflow_info} ->
              {:ok, format_result(result, workflow_info), :on_workflow_created}

            {:error, _reason} ->
              {:ok, format_result(result, nil), :on_created}
          end
        else
          {:ok, format_result(result, nil), :on_created}
        end

      {:error, _} = err ->
        err
    end
  end

  defp generation_loop(_prompt, _skill_name, 0, _config, last_error) do
    {:error, {:generation_failed, last_error}}
  end

  defp generation_loop(prompt, skill_name, retries_left, config, _last_error) do
    case SkillAPI.llm_complete(__MODULE__, prompt, tier: :local, system: @system_prompt) do
      {:ok, response} ->
        case extract_code(response) do
          {:ok, code} ->
            file_name = "#{skill_name}.ex"

            case SkillAPI.write_skill(__MODULE__, file_name, code) do
              :ok ->
                Logger.info("Coder: wrote skill file #{file_name}", skill: :coder)

                case SkillAPI.load_skill(__MODULE__, file_name) do
                  {:ok, info} ->
                    case validate_runtime(info.module) do
                      :ok ->
                        Logger.info("Coder: generated skill code:\n#{code}", skill: :coder)
                        {:ok, Map.put(info, :code, code)}

                      {:error, runtime_error} ->
                        Logger.warning("Coder: runtime validation failed (#{retries_left - 1} retries left): #{inspect(runtime_error)}", skill: :coder)
                        SkillAPI.unload_skill(__MODULE__, info.name)
                        error_hint = "\n\nThe code compiled but failed at runtime: #{inspect(runtime_error)}\nFix the code and try again."
                        generation_loop(prompt <> error_hint, skill_name, retries_left - 1, config, runtime_error)
                    end

                  {:error, reason} ->
                    error_hint = "\n\nThe previous code had this error: #{inspect(reason)}\nFix the code and try again."
                    generation_loop(prompt <> error_hint, skill_name, retries_left - 1, config, reason)
                end

              {:error, reason} ->
                {:error, {:write_failed, reason}}
            end

          :no_code_block ->
            hint = "\n\nYou must wrap the code in ```elixir ... ```. Try again."
            generation_loop(prompt <> hint, skill_name, retries_left - 1, config, :no_code_block)
        end

      {:error, reason} ->
        {:error, {:llm_failed, reason}}
    end
  end

  defp validate_runtime(module) do
    try do
      case module.run(%{input: "test", config: %{}}) do
        {:ok, result, _branch} when is_binary(result) -> :ok
        {:ok, result, _branch} -> {:error, {:runtime_bad_result, "run/1 returned non-string result: #{inspect(result)}"}}
        {:ok, _} -> {:error, {:runtime_bad_result, "run/1 must return {:ok, string, :branch}, got 2-tuple"}}
        {:error, reason} -> {:error, {:runtime_error_returned, "run/1 returned {:error, #{inspect(reason)}} — the skill must return {:ok, result_string, :on_success} for a successful run"}}
        other -> {:error, {:runtime_bad_result, "run/1 returned unexpected: #{inspect(other)}"}}
      end
    rescue
      e -> {:error, {:runtime_crash, Exception.message(e)}}
    catch
      kind, reason -> {:error, {:runtime_crash, "#{kind}: #{inspect(reason)}"}}
    end
  end

  defp extract_code(response) do
    case Regex.run(~r/```elixir\s*\n(.*?)```/s, response) do
      [_, code] -> {:ok, String.trim(code)}
      nil ->
        case Regex.run(~r/```\s*\n(.*?)```/s, response) do
          [_, code] -> {:ok, String.trim(code)}
          nil -> :no_code_block
        end
    end
  end

  defp gather_knowledge(goal) do
    # 1. Skill template/pattern (how to structure the skill)
    template_chunks = search_kb("AlexClaw Skill behaviour SkillAPI dynamic template", 3)

    # 2. Goal-specific across all knowledge (general relevance)
    goal_chunks = search_kb(goal, 3)

    # 3. Targeted Erlang/OTP API docs (exact function signatures)
    erlang_chunks = search_kb(goal, 3, kind: "erlang_docs")

    # 4. Elixir stdlib patterns (idiomatic code examples)
    elixir_chunks = search_kb(goal, 2, kind: "elixir_source")

    # 5. Existing skill source (real working examples)
    skill_chunks = search_kb(goal, 2, kind: "skill_source")

    (template_chunks ++ erlang_chunks ++ elixir_chunks ++ goal_chunks ++ skill_chunks)
    |> Enum.uniq_by(& &1.id)
    |> Enum.map_join("\n---\n", & &1.content)
  end

  defp search_kb(query, limit, opts \\ []) do
    case SkillAPI.knowledge_search(__MODULE__, query, Keyword.merge([limit: limit], opts)) do
      {:ok, entries} -> entries
      _ -> []
    end
  end

  defp build_prompt(goal, skill_name, kb_context) do
    module_name = Macro.camelize(skill_name)

    context_section =
      if kb_context != "" do
        """

        Relevant context from knowledge base:
        #{kb_context}
        """
      else
        ""
      end

    """
    Generate a skill called AlexClaw.Skills.Dynamic.#{module_name} that does the following:

    #{goal}
    #{context_section}
    Remember: module name must be AlexClaw.Skills.Dynamic.#{module_name}
    """
  end

  @filler_words ~w(a an the that which returns gets fetches creates makes builds generates is are was were will would should could can do does did have has had been being be for from with into onto upon about above below between through during before after since until of in on at to by and or but not skill skills)

  defp derive_skill_name(goal) do
    goal
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9\s]/, "")
    |> String.split()
    |> Enum.reject(&(&1 in @filler_words))
    |> Enum.take(4)
    |> Enum.join("_")
    |> String.slice(0, 40)
    |> then(fn name ->
      if name == "", do: "generated_skill", else: name
    end)
  end

  defp create_skill_workflow(skill_name) do
    with {:ok, workflow} <- SkillAPI.create_workflow(__MODULE__, %{name: "Auto: #{skill_name}", enabled: false}),
         {:ok, _step1} <- SkillAPI.add_workflow_step(__MODULE__, workflow.id, %{name: skill_name, skill: skill_name, position: 1}),
         {:ok, _step2} <- SkillAPI.add_workflow_step(__MODULE__, workflow.id, %{name: "notify", skill: "telegram_notify", position: 2}) do
      {:ok, %{workflow_id: workflow.id, workflow_name: workflow.name}}
    end
  end

  defp format_result(result, nil) do
    """
    Skill *#{result.name}* generated and loaded.
    Permissions: #{inspect(result.permissions)}
    Routes: #{inspect(result.routes)}
    """
  end

  defp format_result(result, workflow_info) do
    """
    Skill *#{result.name}* generated and loaded.
    Permissions: #{inspect(result.permissions)}
    Routes: #{inspect(result.routes)}

    Workflow *#{workflow_info.workflow_name}* created (disabled).
    Enable it in Admin > Workflows or run with `/run #{workflow_info.workflow_id}`
    """
  end
end
