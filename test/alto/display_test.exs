defmodule Alto.DisplayTest do
  use ExUnit.Case, async: true
  alias Alto.Display

  test "redacts known credentials in displayed text" do
    for secret <- [
          "sk-example_secret",
          "ghp_example_secret",
          "Bearer opaque",
          "Authorization: Basic dXNlcjpwYXNz",
          "x-api-key: opaque",
          "?api_key=opaque"
        ] do
      text = Display.error(secret)
      assert text =~ "[REDACTED]"
      refute text =~ "example_secret"
      refute text =~ "opaque"
      refute text =~ "dXNlcjpwYXNz"
    end
  end

  test "does not mark short multibyte text as truncated" do
    text = String.duplicate("😀", 2_001)
    assert Display.error(text) == text
  end

  test "provider errors retain the cause and useful fields without Elixir syntax" do
    error =
      {:http_error, 400,
       %{
         "error" => %{
           "message" => "This model does not support tools",
           "code" => "unsupported_parameter"
         },
         "request_id" => "req-123"
       }}

    for value <- [error, Alto.Protocol.encode_term(error)] do
      text = Display.error(value)
      assert text =~ "Provider returned HTTP 400"
      assert text =~ "This model does not support tools"
      assert text =~ "Unsupported parameter"
      assert text =~ "Request id: req-123"
      refute text =~ "%{"
      refute text =~ "$tuple"
      refute text =~ "=>"
    end

    assert Display.error({:catalog_write_failed, :eacces}) ==
             "Catalog write failed: Permission denied"

    assert Display.error({:model_discovery_not_supported, Alto.Providers.OpenAICompatible}) =~
             "does not support model discovery"
  end

  test "tool results and structured failures use labeled fields" do
    text =
      Display.result(
        JSON.encode!(%{
          exit_code: 1,
          stderr: "No such file",
          error: Alto.Protocol.encode_term({:error, :enoent})
        })
      )

    assert text =~ "Exit code: 1"
    assert text =~ "Stderr: No such file"
    assert text =~ "File or folder not found"
    text = Display.error(%{reason: {:error, :eacces}, path: "/tmp/project"})
    assert text =~ "Permission denied"
    assert text =~ "Path: /tmp/project"
    refute text =~ "%{"
    assert Display.result(%{changes: [%{path: "app.ex", lines: 2}]}) =~ "Path: app.ex"
  end

  test "readable display does not evaluate diagnostics or create atoms" do
    target = Path.join(System.tmp_dir!(), "alto-display-#{System.unique_integer([:positive])}")
    text = ~s|%{message: File.write!(#{inspect(target)}, "bad")}|
    assert Display.error(text) == text
    refute File.exists?(target)
    unknown = "untrusted_display_atom_#{System.unique_integer([:positive])}"
    assert Display.error("%{" <> unknown <> ": 1}") == "%{" <> unknown <> ": 1}"
    assert_raise ArgumentError, fn -> String.to_existing_atom(unknown) end
    assert Display.error(%{"$inspect" => "#PID<0.1.0>"}) == "Diagnostic details are unavailable"
  end

  test "conversation text and command output containing code remain literal" do
    source = ~s|%{error: :example, call: File.read!("code.ex")}|
    assert Display.text(source) == source
    assert Display.result(%{stdout: source}) == "Stdout: " <> source
  end

  test "sensitive metadata is redacted and exceptions are readable" do
    text =
      Display.error(
        {:provider_exception, %RuntimeError{message: "Connection failed"},
         [{__MODULE__, :run, 0, []}]}
      )

    assert text == "Provider failed: Connection failed"
    text = Display.error(%{authorization: "Bearer hidden", nested: %{api_key: "secret-value"}})
    assert text =~ "[REDACTED]"
    refute text =~ "hidden"
    refute text =~ "secret-value"
    refute Display.text(%Alto.Credentials{path: "/private", providers: %{}}) =~ "/private"
  end

  test "large or deep diagnostics remain bounded and cannot inject terminal controls" do
    text = Display.result(%{message: "failed\e[2J", values: Enum.to_list(1..200)})
    refute text =~ "\e"
    assert text =~ "…"
    assert String.length(Display.error(String.duplicate("x", 50_000))) <= 8_001
    deep = Enum.reduce(1..40, "end", fn _, value -> %{details: value} end)
    assert String.length(Display.result(deep)) < 300
    assert String.length(Display.error(%{a: String.duplicate("x", 40_000)}, limit: 240)) <= 241
  end
end
