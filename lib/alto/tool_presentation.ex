defmodule Alto.ToolPresentation do
  @moduledoc "Optional host-composed tool-call presentation, independent of execution semantics."
  @callback summary(term(), term(), keyword()) :: String.t()

  @callback result(term(), keyword()) :: String.t()
  @optional_callbacks result: 2

  def validate(nil), do: :ok

  def validate({module, opts}) when is_atom(module) and is_list(opts) do
    if Keyword.keyword?(opts) and Alto.Capabilities.implements?(module, __MODULE__),
      do: :ok,
      else: {:error, :invalid_tool_presenter}
  end

  def validate(_), do: {:error, :invalid_tool_presenter}

  def summary(nil, name, _args), do: to_string(name || "tool")
  def summary({module, opts}, name, args), do: module.summary(name, args, opts)
  def result(nil, _value), do: ""

  def result({module, opts}, value) do
    if function_exported?(module, :result, 2), do: module.result(value, opts), else: ""
  end
end
