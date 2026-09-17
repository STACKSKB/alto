defmodule Alto.Context.Reducers.Handoff do
  @behaviour Alto.Context.Reducer
  alias Alto.Context.Reducer

  @impl true
  def compact(input, model, _opts) do
    input.notify.(
      Alto.Event.live(:context_handoff_started, %{dropped_messages: length(input.middle)})
    )

    request =
      Reducer.request(
        input,
        Alto.Handoff.prompt(input.text, input.max_handoff_bytes),
        Alto.Handoff.prompt("Use the preceding conversation.", input.max_handoff_bytes)
      )

    with {:ok, completion} <- model.(request),
         message when is_binary(message) <- completion[:message],
         {:ok, artifact} <- Alto.Handoff.decode(message, input.max_handoff_bytes),
         {:ok, published} <-
           Alto.Handoff.persist(
             input.session,
             input.artifact_id,
             artifact,
             input.artifact_options
           ) do
      rendered = Alto.Handoff.render(artifact)

      data = %{
        strategy: :handoff,
        reason: input.reason,
        compaction_count: input.count,
        dropped_messages: length(input.middle),
        dropped_bytes: input.middle_bytes,
        source_bytes: byte_size(input.text),
        handoff_bytes: byte_size(rendered),
        kept_messages: length(input.recent),
        directory: published.directory,
        files: published.files,
        next_step: artifact.next_step
      }

      {:ok,
       %{
         content: "[alto handoff: artifacts at #{published.directory}]\n\n" <> rendered,
         data: data,
         events: [:context_handoff_created],
         records: [Alto.Session.handoff_record(Map.put(data, :run_id, input.run_id))]
       }}
    else
      {:error, _} = error -> error
      _ -> {:error, :handoff_response_empty}
    end
  end
end
