defmodule RepositoryMaintenance.WebhookInbox do
  @moduledoc """
  Adapter for `Alto.Listeners.Webhook` enqueue mode.

  Webhook verification and delivery identity happen before this callback. The
  callback only decodes the bounded JSON body and sends the same validated
  report through `RepositoryMaintenance.Workflow.admit/2` used by the CLI.
  """

  @behaviour Alto.Inbox

  @impl true
  def validate_options(opts) do
    with {:ok, queue} <- Keyword.fetch(opts, :queue),
         true <- is_atom(queue) or is_pid(queue) or is_tuple(queue),
         {:ok, source} <- Keyword.fetch(opts, :source),
         true <- is_binary(source) and source != "" and byte_size(source) <= 256 do
      :ok
    else
      _ -> {:error, :invalid_webhook_inbox_options}
    end
  end

  @impl true
  def admit(_delivery_key, %{"delivery_id" => delivery_id, "body" => body}, opts)
      when is_binary(delivery_id) and is_binary(body) do
    with {:ok, report} <- JSON.decode(body),
         true <- is_map(report) or {:error, :invalid_report} do
      report =
        report
        |> Map.put("source", Keyword.fetch!(opts, :source))
        |> Map.put("delivery_id", delivery_id)

      RepositoryMaintenance.Workflow.admit(Keyword.fetch!(opts, :queue), report)
    end
  end

  def admit(_delivery_key, _payload, _opts), do: {:error, :invalid_report}
end
