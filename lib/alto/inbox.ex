defmodule Alto.Inbox do
  @moduledoc """
  Admission boundary for durable work received from an external source.

  A backend must durably establish delivery identity before returning success.
  Database-backed adapters may insert the source delivery and its execution job
  in one transaction. Backends own their I/O timeout and return only after the
  admission outcome is known.

  This behaviour covers synchronous admission only. Starting, supervising, and
  retrying workers belongs to the host application. The core Alto loop does not
  start or require a backend.
  """

  @type admission_result ::
          {:ok, term()}
          | {:error, :duplicate | :full | :payload_too_large | term()}

  @callback admit(delivery_key :: String.t(), payload :: map(), keyword()) :: admission_result()

  @doc "Validate options without performing I/O or starting backend processes."
  @callback validate_options(keyword()) :: :ok | {:error, term()}
  @optional_callbacks validate_options: 1

  @doc "Validate a configured backend and its options without starting it."
  @spec validate_backend(module(), keyword()) :: :ok | {:error, term()}
  def validate_backend(backend, opts) when is_atom(backend) and is_list(opts) do
    cond do
      not Keyword.keyword?(opts) ->
        {:error, :invalid_inbox_options}

      not Code.ensure_loaded?(backend) or not function_exported?(backend, :admit, 3) ->
        {:error, :invalid_inbox_backend}

      function_exported?(backend, :validate_options, 1) ->
        invoke_validation(backend, opts)

      true ->
        :ok
    end
  end

  def validate_backend(_backend, _opts), do: {:error, :invalid_inbox_backend}

  @doc "Invoke a backend without allowing adapter crashes or invalid replies across the boundary."
  @spec admit(module(), String.t(), map(), keyword()) :: admission_result()
  def admit(backend, delivery_key, payload, opts) do
    backend.admit(delivery_key, payload, opts)
    |> normalize_result()
  rescue
    exception -> {:error, {:inbox_unavailable, Exception.message(exception)}}
  catch
    :exit, reason -> {:error, {:inbox_unavailable, reason}}
    kind, reason -> {:error, {:inbox_unavailable, {kind, reason}}}
  end

  defp invoke_validation(backend, opts) do
    case backend.validate_options(opts) do
      :ok -> :ok
      {:error, _reason} = error -> error
      other -> {:error, {:invalid_inbox_validation_result, other}}
    end
  rescue
    exception -> {:error, {:invalid_inbox_options, Exception.message(exception)}}
  catch
    kind, reason -> {:error, {:invalid_inbox_options, {kind, reason}}}
  end

  defp normalize_result({:ok, _record} = ok), do: ok
  defp normalize_result({:error, _reason} = error), do: error
  defp normalize_result(other), do: {:error, {:invalid_inbox_result, other}}
end
