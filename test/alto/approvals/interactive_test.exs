defmodule Alto.Approvals.InteractiveTest do
  use ExUnit.Case, async: true

  alias Alto.Approval.Request
  alias Alto.Approvals.Interactive
  alias Alto.Tool.Context

  @context %Context{session_id: "test-session", cwd: "/home/three/work"}

  defp plain_request(details \\ %{}) do
    %Request{
      id: "call-1",
      tool: "read_file",
      arguments: %{"path" => "a.txt", "offset" => 0, "limit" => 100},
      execution_mode: :parallel,
      details: details
    }
  end

  defp command_details(overrides \\ %{}) do
    Map.merge(
      %{
        command: %{
          requested_program: "true",
          executable: "/usr/bin/true",
          args: ["--flag", "value"],
          cwd: "/home/three/work",
          timeout_ms: 30_000,
          max_output_bytes: 64_000
        },
        execution: %{
          backend: :bubblewrap,
          bubblewrap: "/usr/bin/bwrap",
          network: :disabled,
          workspace: :read_write,
          read_only_paths: [],
          writable_paths: [],
          environment_variables: ["HOME", "PATH"]
        }
      },
      overrides
    )
  end

  defp attempt(input_text, request) do
    {:ok, input} = StringIO.open(input_text)
    {:ok, output} = StringIO.open("")
    decision = Interactive.decide(request, @context, input: input, output: output)
    {_status, body} = StringIO.contents(output)
    {decision, body}
  end

  defp decide(input_text, request) do
    attempt(input_text, request) |> elem(0)
  end

  describe "decision" do
    test "y approves" do
      assert :approve = decide("y\n", plain_request())
    end

    test "yes approves" do
      assert :approve = decide("yes\n", plain_request())
    end

    test "approval input is case-insensitive and trimmed" do
      for answer <- ["Y", "YES", "  y  ", " yes "] do
        assert :approve = decide(answer <> "\n", plain_request())
      end
    end

    test "empty input denies" do
      assert {:deny, :user_denied} = decide("\n", plain_request())
    end

    test "negative input denies" do
      for answer <- ["n", "no", "N", "cancel", " never "] do
        assert {:deny, :user_denied} = decide(answer <> "\n", plain_request())
      end
    end

    test "EOF denies with an input-closed reason" do
      assert {:deny, :input_closed} = decide("", plain_request())
    end
  end

  describe "presentation" do
    test "prints the tool name, cwd, and raw arguments" do
      {_decision, body} = attempt("y\n", plain_request())

      assert body =~ "tool: read_file"
      assert body =~ "cwd:  /home/three/work"
      assert body =~ ~s("path" => "a.txt")
      assert body =~ ~s("offset" => 0)
      assert body =~ ~s("limit" => 100)
    end

    test "shows the canonical executable, argv, limits, and executor profile" do
      request = plain_request(command_details())
      {_decision, body} = attempt("y\n", request)

      assert body =~ "prepared:"
      assert body =~ ~s(requested_program: "true")
      assert body =~ ~s(executable: "/usr/bin/true")
      assert body =~ ~s(args: ["--flag", "value"])
      assert body =~ ~s(cwd: "/home/three/work")
      assert body =~ "timeout_ms: 30000"
      assert body =~ "max_output_bytes: 64000"
      assert body =~ "backend: :bubblewrap"
      assert body =~ "network: :disabled"
      assert body =~ "workspace: :read_write"
    end

    test "renders the environment variable names supplied by preparation" do
      request =
        plain_request(
          command_details(%{
            execution: %{
              backend: :bubblewrap,
              bubblewrap: "/usr/bin/bwrap",
              network: :disabled,
              workspace: :read_write,
              read_only_paths: [],
              writable_paths: [],
              environment_variables: ["ALTO_TOKEN_NAME", "HOME", "PATH"]
            }
          })
        )

      {_decision, body} = attempt("y\n", request)

      assert body =~ "ALTO_TOKEN_NAME"
      assert body =~ ~s(environment_variables: ["ALTO_TOKEN_NAME", "HOME", "PATH"])
    end

    test "omits the prepared label when there are no prepared details" do
      {_decision, body} = attempt("y\n", plain_request())
      refute body =~ "prepared:"
    end

    test "real unsandboxed preparation surfaces the canonical executable and limits" do
      context = %Context{session_id: "test", cwd: "/home/three/work"}

      {:ok, prepared} =
        Alto.Command.prepare(%{"program" => "true", "args" => ["--hello"]}, context)

      request = plain_request(prepared.approval_details)
      {_decision, body} = attempt("y\n", request)

      assert body =~ "requested_program: \"true\""
      assert body =~ "executable: "
      assert body =~ ~s(args: ["--hello"])
      assert body =~ "timeout_ms: 30000"
      assert body =~ "max_output_bytes: 64000"
      assert body =~ "backend: :unsandboxed"
      assert body =~ "isolation: :none"
    end
  end
end
