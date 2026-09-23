defmodule Alto.Providers.ObserveTest do
  use ExUnit.Case, async: true
  alias Alto.Providers.Observe

  defmodule RetryingProvider do
    def describe(_opts), do: %{}

    def stream(_request, _sink, opts) do
      case Agent.get_and_update(opts[:counter], &{&1, &1 + 1}) do
        0 -> {:error, {:transport_error, :closed}}
        _ -> {:ok, %{message: "recovered", tool_calls: []}}
      end
    end
  end

  test "observations do not suppress retry of a failed transport attempt" do
    counter = start_supervised!({Agent, fn -> 0 end})
    owner = self()

    provider =
      Observe.wrap({RetryingProvider, counter: counter}, fn _ -> send(owner, :observed) end)

    assert {:ok, %{output: "recovered"}} =
             Alto.run("hello", provider: provider, tools: [], provider_retries: 1)

    assert Agent.get(counter, & &1) == 2
    assert_receive :observed
    assert_receive :observed
  end

  defmodule Provider do
    def describe(opts), do: %{model: opts[:model]}
    def list_models(opts), do: {:ok, opts}

    def stream(request, sink, opts) do
      send(opts[:owner], {:request, request, opts})
      sink.(Alto.Event.live(:text_delta, %{text: "hello"}))
      {:ok, %{message: "hello", tool_calls: []}}
    end
  end

  test "nested observers preserve requests, options, discovery, description and stream output" do
    owner = self()

    {module, opts} =
      {Provider, owner: owner, model: "first"}
      |> Observe.wrap(fn request -> send(owner, {:inner, request}) end)
      |> Observe.wrap(fn request -> send(owner, {:outer, request}) end)

    opts = Keyword.put(opts, :model, "selected")
    assert module.describe(opts) == %{model: "selected"}
    assert {:ok, underlying} = module.list_models(opts)
    assert underlying == [model: "selected", owner: owner]
    request = %{messages: [], tools: []}

    assert {:ok, %{message: "hello"}} =
             module.stream(request, &send(owner, {:event, &1}), opts)

    assert_receive {:outer, ^request}
    assert_receive {:inner, ^request}
    assert_receive {:request, ^request, ^underlying}
    assert_receive {:event, %Alto.Event{type: :text_delta}}
  end

  test "observer failures do not prevent provider execution" do
    for observer <- [
          fn _ -> raise "diagnostics failed" end,
          fn _ -> throw(:failed) end,
          fn _ -> exit(:failed) end
        ] do
      {module, opts} = Observe.wrap({Provider, owner: self()}, observer)
      assert {:ok, _} = module.stream(%{}, fn _ -> :ok end, opts)
      assert_receive {:request, %{}, _}
    end
  end
end
