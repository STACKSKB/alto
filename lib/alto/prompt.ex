defmodule Alto.Prompt do
  @moduledoc "Construction and rendering for replaceable system-prompt builders."

  @type fragment :: binary()
  @type builder ::
          binary()
          | nil
          | module()
          | {module(), keyword()}
          | (Alto.Prompt.Builder.context() -> binary())

  @doc "Resolve literal text, nil, a module, a configured module, or a function."
  @spec build(builder(), Alto.Prompt.Builder.context()) ::
          {:ok, binary() | nil} | {:error, term()}
  def build(value, _context) when value in [nil, ""], do: {:ok, nil}
  def build(value, _context) when is_binary(value), do: {:ok, value}

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
