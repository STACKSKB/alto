defmodule Alto.Approval do
  @moduledoc """
  Approval decisions and front-end functions for authorizing one external effect.

  Configure a literal decision or a two-argument function. Closures can capture
  options for `interactive/3` or `delegated/3`. The execution host freezes the
  prepared request and supervises every decision with timeout and cancellation;
  front ends receive display-safe details and reply to the exact request ID.

  Requests are maps with all seven fields in `request/0`. `run_id` identifies the
  owning run; `call_id` is correlation only and may repeat or be nil. The globally
  unique `id` ("<run_id>:op-<seq>") authorizes exactly one prepared value. Front
  ends answer with that ID, never the bare call ID.
  """

  @type request :: %{
          id: String.t() | nil,
          run_id: String.t() | nil,
          call_id: String.t() | nil,
          tool: String.t(),
          arguments: map(),
          execution_mode: Alto.Tool.execution_mode(),
          details: map()
        }

  @type decision :: :approve | :suspend | {:deny, term()}

  @type policy :: decision() | (request(), Alto.Tool.context() -> decision())

  @doc "Ask for one invocation's approval over line-oriented input."
  def interactive(request, context, opts \\ []) do
    input = Keyword.get(opts, :input, :stdio)
    output = Keyword.get(opts, :output, :stderr)

    IO.write(output, """

    Approval required
      tool: #{request.tool}
      cwd:  #{context.cwd}
      arguments: #{inspect(request.arguments, pretty: true, limit: 20, printable_limit: 2_000)}
    #{format_details(request.details)}
    """)

    case IO.gets(input, "Approve this invocation? [y/N] ") do
      answer when is_binary(answer) ->
        if String.downcase(String.trim(answer)) in ["y", "yes"],
          do: :approve,
          else: {:deny, :user_denied}

      :eof ->
        {:deny, :input_closed}

      {:error, reason} ->
        {:deny, {:input_error, reason}}
    end
  end

  @doc "Ask a trusted local front end, using its inherited sink and owning-run route."
  def delegated(request, context, opts \\ []) do
    sink = Keyword.get(opts, :sink) || get_in(context[:metadata], [:approval_sink])

    if is_pid(sink) do
      route = get_in(context[:metadata], [:approval_route]) || context.session_id
      send(sink, {:alto_approval_request, route, request, self()})
      await_decision(request.id)
    else
      {:deny, :approval_front_end_unavailable}
    end
  end

  @doc "Ask attached resident front ends; unavailable registries deny immediately."
  def socket(%{id: nil}, _context), do: {:deny, :approval_request_unaddressable}

  def socket(%{id: _} = request, context) do
    registry =
      Map.get(context[:metadata] || %{}, :front_end_registry, Alto.FrontEnd.Registry)

    case Alto.FrontEnd.Registry.request(
           registry,
           {:request_approval, context.session_id, request, self()}
         ) do
      :ok -> await_decision(request.id)
      {:error, reason} -> {:deny, {:approval_unavailable, reason}}
    end
  catch
    :exit, reason -> {:deny, {:approval_unavailable, {:registry_exit, reason}}}
  end

  defp await_decision(id) do
    receive do
      {:alto_approval_decision, ^id, decision} -> decision
    end
  end

  defp format_details(details) when details == %{}, do: ""

  defp format_details(details),
    do: "  prepared: " <> inspect(details, pretty: true, limit: 50, printable_limit: 4_000)
end
