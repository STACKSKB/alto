defmodule Alto.Prompt do
  @moduledoc "Construction and rendering for replaceable system-prompt builders."

  @type fragment :: binary()
  @type builder :: module() | {module(), keyword()} | (Alto.Prompt.Builder.context() -> binary())

  @doc "Build a prompt with a module, configured module, or function."
  @spec build(builder(), Alto.Prompt.Builder.context()) :: {:ok, binary()} | {:error, term()}
  def build({module, opts}, context) when is_atom(module) and is_list(opts) do
    validate(fn -> module.build(context, opts) end)
  end

  def build(module, context) when is_atom(module) do
    build({module, []}, context)
  end

  def build(builder, context) when is_function(builder, 1) do
    validate(fn -> builder.(context) end)
  end

  def build(builder, _context), do: {:error, {:invalid_prompt_builder, builder}}

  @doc "Compatibility constructor for the shipped coding prompt."
  @spec coding_agent(binary(), keyword()) :: binary()
  def coding_agent(cwd, opts \\ []) do
    {:ok, prompt} =
      build(Alto.Prompts.Coding, %{cwd: cwd, tools: Keyword.get(opts, :tools, [])})

    prompt
  end

  @doc "Render prompt fragments with stable separation."
  @spec render([fragment()]) :: binary()
  def render(fragments), do: Enum.join(fragments, "\n") <> "\n"

  defp validate(fun) do
    case fun.() do
      prompt when is_binary(prompt) and prompt != "" -> {:ok, prompt}
      other -> {:error, {:invalid_prompt, other}}
    end
  rescue
    error -> {:error, {:prompt_builder_failed, error, __STACKTRACE__}}
  catch
    kind, reason -> {:error, {:prompt_builder_failed, {kind, reason}}}
  end
end
