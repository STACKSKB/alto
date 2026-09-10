defmodule Alto.Approval.Request do
  @moduledoc """
  A display-safe description of one tool invocation awaiting authorization.

  Operation identities:

    * `run_id` — the host run that owns the operation (`tool_context.session_id`,
      globally unique per run).
    * `call_id` — provider/native tool-call correlation token. It may repeat
      (a provider may reuse ids) or be `nil` (native `invoke_tool` without an
      id). It is preserved for transcript and loop correlation but is never
      an approval handle.
    * `operation_id` — runtime operation identity, globally unique per tool
      invocation (`"<run_id>:op-<seq>"`). One operation prepares exactly one
      opaque value.
    * `id` — the approval handle. It coincides 1:1 with `operation_id`: the
      decision recorded for `id` authorizes exactly the prepared value of
      that operation, and no other.

  Approval handles are globally unambiguous across concurrent runs, nested
  runs, and repeated provider call ids. Front ends answer `approval_response`
  with the handle (`id`/`operation_id`), never the bare `call_id`.
  """

  @enforce_keys [:id, :tool, :arguments, :execution_mode]
  defstruct [
    :id,
    :tool,
    :arguments,
    :execution_mode,
    :run_id,
    :call_id,
    :operation_id,
    details: %{}
  ]

  @type t :: %__MODULE__{
          id: String.t() | nil,
          tool: String.t(),
          arguments: map(),
          execution_mode: Alto.Tool.execution_mode(),
          run_id: String.t() | nil,
          call_id: String.t() | nil,
          operation_id: String.t() | nil,
          details: map()
        }
end
