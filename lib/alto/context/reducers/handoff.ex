defmodule Alto.Context.Reducers.Handoff do
  @behaviour Alto.Context.Reducer
  alias Alto.Context.Reducer

  @impl true
  def compact(input, model, _opts) do
    request =
      Reducer.request(
        input,
        Alto.Handoff.prompt(input.text, input.max_handoff_bytes),
        Alto.Handoff.prompt("Use the preceding conversation.", input.max_handoff_bytes)
      )

    with {:ok, completion} <- model.(request),
         message when is_binary(message) <- completion[:message],
         {:ok, artifact} <- Alto.Handoff.decode(message, input.max_handoff_bytes),
         {:ok, path} <-
           Alto.Handoff.persist(
             input.session,
             input.artifact_id,
             artifact,
             input.artifact_options
           ) do
      rendered = Alto.Handoff.render(artifact)

      data = %{
        strategy: :handoff,
        source_bytes: byte_size(input.text),
        handoff_bytes: byte_size(rendered),
        artifact_path: path,
        next_step: artifact.next_step
      }

      {:ok,
       %{
         content: "[alto handoff: artifact at #{path}]\n\n" <> rendered,
         data: data
       }}
    else
      {:error, _} = error -> error
      _ -> {:error, :handoff_response_empty}
    end
  end
end
