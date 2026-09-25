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
    * `id` — globally unique runtime operation identity and approval handle
      (`"<run_id>:op-<seq>"`). Its decision authorizes exactly one prepared value.

  Handles remain unambiguous across concurrent runs, nested runs, and repeated
  provider call ids. Front ends answer `approval_response` with `id`, never
  the bare `call_id`.
  """

  @enforce_keys [:id, :tool, :arguments, :execution_mode]
  defstruct [
    :id,
    :tool,
    :arguments,
    :execution_mode,
    :run_id,
    :call_id,
    details: %{}
  ]

  @type t :: %__MODULE__{
          id: String.t() | nil,
          tool: String.t(),
          arguments: map(),
          execution_mode: Alto.Tool.execution_mode(),
          run_id: String.t() | nil,
          call_id: String.t() | nil,
          details: map()
        }
end
