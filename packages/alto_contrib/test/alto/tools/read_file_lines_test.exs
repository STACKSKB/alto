defmodule Alto.Contrib.Tools.ReadFileLinesTest do
  use ExUnit.Case, async: true
  alias Alto.Contrib.Tools.ReadFile

  setup do
    root = Path.join(System.tmp_dir!(), "alto-lines-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    File.write!(Path.join(root, "source"), "α\r\nsecond line\nthird\nlast")
    %{root: root, context: %{cwd: root}}
  end

  test "source line ranges align with search and continue without skipping", %{context: ctx} do
    assert {:ok,
            %{
              content: "second line\nthird\n",
              start_line: 2,
              returned_lines: 2,
              next_line: 4,
              next_offset: 22,
              truncated: true
            }} =
             Alto.Tool.run(
               ReadFile,
               %{"path" => "source", "start_line" => 2, "line_count" => 2},
               ctx
             )

    assert {:ok, %{content: "last", next_line: nil, truncated: false}} =
             Alto.Tool.run(ReadFile, %{"path" => "source", "start_line" => 4}, ctx)

    assert {:ok, %{content: "", truncated: false}} =
             Alto.Tool.run(ReadFile, %{"path" => "source", "start_line" => 100}, ctx)
  end

  test "byte ceiling mid-line provides byte continuation", %{context: ctx} do
    assert {:ok,
            %{content: "sec", partial_line: true, next_line: nil, next_offset: 7, truncated: true}} =
             Alto.Tool.run(ReadFile, %{"path" => "source", "start_line" => 2, "limit" => 3}, ctx)

    assert {:ok, %{content: "ond line\nthird\nlast", range_unit: "bytes"}} =
             Alto.Tool.run(ReadFile, %{"path" => "source", "offset" => 7}, ctx)
  end

  test "rejects conflicting units and bounds scans and binary output", %{root: root, context: ctx} do
    assert {:error, {:conflicting_read_units, _}} =
             Alto.Tool.run(ReadFile, %{"path" => "source", "offset" => 5, "start_line" => 2}, ctx)

    assert {:error, {:missing_start_line, _}} =
             Alto.Tool.run(ReadFile, %{"path" => "source", "line_count" => 2}, ctx)

    assert {:error, {:line_scan_limit, 5, _}} =
             Alto.Tool.run(ReadFile, %{"path" => "source", "start_line" => 3}, ctx,
               max_scan_bytes: 5
             )

    assert {:error, {:line_scan_limit, 4, _}} =
             Alto.Tool.run(ReadFile, %{"path" => "source", "start_line" => 2}, ctx,
               max_scan_bytes: 4
             )

    File.write!(Path.join(root, "binary"), <<255, 10, 0>>)

    assert {:ok, %{content_base64: "/wo=", encoding: "base64", next_line: 2}} =
             Alto.Tool.run(
               ReadFile,
               %{"path" => "binary", "start_line" => 1, "line_count" => 1},
               ctx
             )
  end
end
