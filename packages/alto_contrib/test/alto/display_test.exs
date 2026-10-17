defmodule Alto.DisplayTest do
  use ExUnit.Case, async: true
  alias Alto.Contrib.Display

  test "redacts known credentials in displayed text" do
    for {secret, value} <- [
          {"sk-example_secret", "example_secret"},
          {"ghp_example_secret", "example_secret"},
          {"Bearer opaque", "opaque"},
          {"Authorization: Basic dXNlcjpwYXNz", "dXNlcjpwYXNz"},
          {"x-api-key: opaque", "opaque"},
          {"?api_key=opaque", "opaque"},
          {~s|Server said: {"api_key": "opaque", "status": "failed"}|, "opaque"},
          {~s|Server said: token: "opaque"|, "opaque"}
        ] do
      text = Display.error(secret)
      assert text =~ "[REDACTED]"
      refute text =~ value
    end
  end

  test "bounds multibyte text by UTF-8 bytes without clipping a character" do
    fitting = String.duplicate("😀", 2_000)
    assert Display.error(fitting) == fitting

    truncated = Display.error(fitting <> "😀")
    assert String.valid?(truncated)
    assert byte_size(truncated) <= 8_000
    assert String.ends_with?(truncated, "…")
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
    refute Display.text(%Alto.Contrib.Credentials{path: "/private", providers: %{}}) =~ "/private"
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
