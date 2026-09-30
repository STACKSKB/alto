defmodule Alto.Contrib.Approval do
  @moduledoc "Approval front ends for terminal and resident applications."

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

      case await_decision(request.id) do
        {:review, reviewer} when is_function(reviewer, 2) ->
          Alto.Approval.review(reviewer, request, context)

        decision ->
          decision
      end
    else
      {:deny, :approval_front_end_unavailable}
    end
  end

  @doc "Ask attached resident front ends; unavailable registries deny immediately."
  def socket(%{id: nil}, _context), do: {:deny, :approval_request_unaddressable}

  def socket(%{id: _} = request, context) do
    registry =
      Map.get(context[:metadata] || %{}, :front_end_registry, Alto.Contrib.FrontEnd.Registry)

    case Alto.Contrib.FrontEnd.Registry.request(
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
