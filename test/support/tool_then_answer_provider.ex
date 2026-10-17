defmodule Alto.TestSupport.ToolThenAnswerProvider do
  @behaviour Alto.Provider

  @impl true
  def describe(_opts), do: %{}

  @impl true
  def stream(request, sink, opts) do
    if pid = Keyword.get(opts, :test_pid), do: send(pid, {:provider_request, request})
    if delta = Keyword.get(opts, :delta), do: sink.(Alto.Event.live(:model_delta, %{text: delta}))

    if Enum.any?(request.messages, &(&1["role"] == "tool")) do
      {:ok, %{message: "finished", tool_calls: []}}
    else
      {:ok,
       %{
         message: nil,
         tool_calls: [%{id: "call-1", name: "echo", arguments_json: ~s({"value":"hello"})}]
       }}
    end
  end
end
