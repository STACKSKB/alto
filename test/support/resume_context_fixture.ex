defmodule Alto.Test.ResumeContextFixture do
  # Each new tool suffix fits the window, but the complete serialized history
  # does not. Only genuine counts from successful provider turns let it grow.
  defmodule PayloadTool do
    @behaviour Alto.Tool
    def name, do: :payload

    def schema do
      %{
        description: "Return authored test text.",
        parameters: %{type: "object", properties: %{}, required: []}
      }
    end

    def execution_mode, do: :parallel
    def approval, do: :never
    def run(_, _), do: {:ok, %{text: String.duplicate("x", 1_800)}}
  end

  defmodule Provider do
    @behaviour Alto.Provider
    def describe(opts), do: %{context_window: 4_096, model: opts[:model]}

    def stream(request, _sink, opts) do
      turns = Enum.count(request.messages, &(&1["role"] == "tool"))
      continuing = Enum.any?(request.messages, &(&1["content"] == "continue"))

      if continuing or turns >= 3 do
        {:ok,
         %{
           message: "done",
           tool_calls: [],
           usage: Keyword.get(opts, :final_usage, %{input_tokens: 100})
         }}
      else
        {:ok,
         %{
           message: nil,
           tool_calls: [
             %{id: "payload-#{turns}", name: "payload", arguments_json: "{}"}
           ],
           usage: %{input_tokens: 100}
         }}
      end
    end
  end

  defmodule OtherProvider do
    @behaviour Alto.Provider
    defdelegate describe(opts), to: Provider
    defdelegate stream(request, sink, opts), to: Provider
  end

  defmodule Reducer do
    @behaviour Alto.Context.Reducer
    def compact(_, _, _),
      do:
        {:ok,
         %{content: "Earlier authored test work summarized.", data: %{}, events: [], records: []}}
  end
end
