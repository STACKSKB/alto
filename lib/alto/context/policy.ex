defmodule Alto.Context.Policy do
  @moduledoc """
  Context admission contract. A policy is `{module, state}` implementing
  `check/3`; `nil` explicitly disables admission. Callbacks run
  under the provider deadline and return an output reservation and optional
  pressure signal; they never modify the request or grant tool authority.
  """
  @callback check(term(), map(), map()) ::
              {:ok, :unavailable | map()} | {:error, term()}

  def validate(nil), do: :ok

  def validate({module, _}) do
    if Alto.Capabilities.implements?(module, __MODULE__),
      do: :ok,
      else: {:error, :invalid_context_policy}
  end

  def validate(_), do: {:error, :invalid_context_policy}

  def check(nil, _request, _description), do: {:ok, :unavailable}

  def check({module, options}, request, description),
    do: normalize(module.check(options, request, description))

  defp normalize({:ok, :unavailable} = result), do: result

  defp normalize({:ok, %{reserve_output: reserve} = budget} = result)
       when is_integer(reserve) and reserve >= 0 do
    if is_boolean(Map.get(budget, :pressure, false)),
      do: result,
      else: {:error, :invalid_context_policy_result}
  end

  defp normalize({:error, _} = error), do: error
  defp normalize(_), do: {:error, :invalid_context_policy_result}
end
