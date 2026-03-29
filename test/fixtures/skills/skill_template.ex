# ==============================================================================
# AlexClaw Dynamic Skill Template
# ==============================================================================
#
# How to create a dynamic skill:
#
# 1. Copy this file and rename it (e.g. my_skill.ex)
# 2. Rename the module to AlexClaw.Skills.Dynamic.MySkill
#    (must be under AlexClaw.Skills.Dynamic.*)
# 3. Set your permissions — only request what you need
# 4. Implement run/1 — receives args map from the workflow executor
# 5. Upload via Admin > Skills, or copy to the skills volume and
#    use /skill load my_skill.ex in Telegram
#
# Available permissions:
#   :llm            — Call LLM models (complete, system_prompt)
#   :web_read       — HTTP requests (GET, POST, any method)
#   :telegram_send  — Send messages to Telegram
#   :memory_read    — Search/check memory entries
#   :memory_write   — Store new memory entries
#   :config_read    — Read config values from the database
#   :resources_read — List and read resources
#   :skill_invoke   — Call other skills by name
#
# The args map passed to run/1 contains:
#   args[:input]          — Output from the previous workflow step (or user input)
#   args[:config]         — Step-specific config map (set in the workflow editor)
#   args[:resources]      — List of resources assigned to the workflow
#   args[:llm_provider]   — LLM provider name (or nil for auto)
#   args[:llm_tier]       — Requested tier (light/medium/heavy/local)
#   args[:prompt_template] — Optional prompt template
#   args[:workflow_run_id] — Current workflow run ID
#
# Return format:
#   {:ok, result, :branch_name}  — success with branch for conditional routing
#   {:ok, result}                — success (treated as :on_success for routing)
#   {:error, reason}             — failure (treated as :on_error for routing)
#
# Optional routes/0 callback:
#   Declares available branches for the workflow editor. If not implemented,
#   defaults to [:on_success, :on_error]. Example:
#     def routes, do: [:on_results, :on_empty, :on_error]
#
# Optional external/0 callback:
#   MUST be declared if the skill makes HTTP requests (Req.get, Req.post,
#   SkillAPI.http_get, SkillAPI.http_post, etc.). The system AST-scans for
#   HTTP calls at load time — undeclared external calls will REJECT the skill.
#   Example:
#     def external, do: true
#
# ==============================================================================

defmodule AlexClaw.Skills.Dynamic.SkillTemplate do
  @behaviour AlexClaw.Skill

  alias AlexClaw.Skills.SkillAPI

  @impl true
  def version, do: "1.0.0"

  # Only request the permissions your skill actually uses.
  @impl true
  def permissions, do: [:llm]

  @impl true
  def description, do: "Template skill — replace with your description"

  # Optional: declare branches for conditional workflow routing.
  # The workflow editor will show these as routing options per step.
  # @impl true
  # def routes, do: [:on_success, :on_empty, :on_error]

  # Required if the skill makes HTTP requests (Req, SkillAPI.http_*).
  # Undeclared external calls will cause the skill to be REJECTED at load time.
  # @impl true
  # def external, do: true

  # Declares which fields the workflow step editor shows for this skill.
  # Use [:config] for skills that don't need LLM. Use [] for no config at all.
  @impl true
  def step_fields, do: [:llm_tier, :llm_model, :prompt_template, :config]

  # JSON hint shown as placeholder in the config textarea.
  # @impl true
  # def config_hint, do: ~s|{"param": "value"}|

  # Default config map pre-filled when adding a new step.
  # @impl true
  # def config_scaffold, do: %{"param" => "default_value"}

  @impl true
  def run(args) do
    input = args[:input]
    config = args[:config] || %{}

    # Example: simple LLM call with branch routing
    prompt = config["prompt"] || "Summarize the following:\n\n#{input}"

    case SkillAPI.llm_complete(__MODULE__, prompt, tier: :light) do
      {:ok, response} ->
        # Return triple tuple: {:ok, result, :branch_name}
        # The branch determines which workflow path to take next
        {:ok, response, :on_success}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # ---------------------------------------------------------------------------
  # SkillAPI reference — uncomment what you need
  # ---------------------------------------------------------------------------
  #
  # LLM
  #   SkillAPI.llm_complete(__MODULE__, prompt, tier: :light)
  #   SkillAPI.llm_complete(__MODULE__, prompt, tier: :medium, provider: "gemini-pro")
  #   SkillAPI.system_prompt(__MODULE__, %{skill: :research})
  #
  # Telegram
  #   SkillAPI.send_telegram(__MODULE__, "markdown *message*")
  #   SkillAPI.send_telegram_html(__MODULE__, "<b>html message</b>")
  #
  # Memory
  #   SkillAPI.memory_search(__MODULE__, "query", limit: 10, kind: "summary")
  #   SkillAPI.memory_recent(__MODULE__, limit: 20, kind: "news_item")
  #   SkillAPI.memory_exists?(__MODULE__, "https://some-url.com")
  #   SkillAPI.memory_store(__MODULE__, :my_kind, "content", source: "url", metadata: %{})
  #
  # HTTP
  #   SkillAPI.http_get(__MODULE__, url, headers: [...], receive_timeout: 10_000)
  #   SkillAPI.http_post(__MODULE__, url, json: body, headers: [...])
  #   SkillAPI.http_request(__MODULE__, :put, url, json: body)
  #
  # Config
  #   SkillAPI.config_get(__MODULE__, "some.config.key", "default")
  #
  # Resources
  #   SkillAPI.list_resources(__MODULE__, %{type: "rss_feed", enabled: true})
  #   SkillAPI.get_resource(__MODULE__, 42)
  #
  # Cross-skill invocation
  #   SkillAPI.run_skill(__MODULE__, "web_search", %{input: "query"})
  #
end
