defmodule Alto.Tools.ReadFile do
  @moduledoc "Bounded, workspace-confined byte and source-line reads."
  use Alto.Tool, name: :read_file, execution_mode: :parallel, approval: :never, arguments: true
  alias Alto.Tools.Path, as: SafePath

  # Leave room for metadata and base64 within the default native result bound.
  @impl true
  def options, do: %{max_bytes: 47_000, max_scan_bytes: 1_000_000}

  @impl true
  def arguments(opts) do
    {"Read a workspace file. For source line ranges use start_line and line_count (1-based lines, matching search_files results). Omit them to read bytes. Results include continuation positions when truncated.",
     [
       path: [
         type: :string,
         required: true,
         doc: "Workspace-relative or in-workspace absolute path."
       ],
       start_line: [
         type: :pos_integer,
         doc: "First source line, starting at 1. Use with line_count, not offset."
       ],
       line_count: [
         type: {:in, 1..2000},
         doc: "Number of lines (default 200 when start_line is set). Requires start_line."
       ],
       offset: [
         type: :non_neg_integer,
         default: 0,
         doc: "Byte offset, NOT a line number. Omit for line-range reads."
       ],
       limit: [
         type: {:in, 1..opts.max_bytes},
         default: opts.max_bytes,
         doc: "Maximum output BYTES in either mode, not a line count."
       ]
     ]}
  end

  @impl true
  def run(arguments, %{} = context, opts \\ []) do
    with {:ok, resolved} <- SafePath.resolve(arguments["path"], context.cwd),
         {:ok, content, metadata} <- read(resolved, arguments, opts) do
      encoded =
        if String.valid?(content),
          do: %{content: Alto.Retained.detach(content)},
          else: %{content_base64: Base.encode64(content), encoding: "base64"}

      {:ok, encoded |> Map.merge(metadata) |> Map.put(:path, arguments["path"])}
    end
  end

  defp read(path, %{"start_line" => start} = args, opts) do
    if args["offset"] != 0 do
      {:error,
       {:conflicting_read_units,
        "Use start_line/line_count for lines OR offset/limit for bytes; omit offset in line mode."}}
    else
      scan_limit = opts.max_scan_bytes

      with {:ok, scanned} <- Alto.BoundedFile.range(path, 0, scan_limit + 1) do
        more = byte_size(scanned) > scan_limit
        bytes = binary_part(scanned, 0, min(byte_size(scanned), scan_limit))

        case line_offset(bytes, start - 1, 0) do
          position when more and (position == :past_end or position == byte_size(bytes)) ->
            {:error,
             {:line_scan_limit, scan_limit,
              "Requested line is beyond the bounded scan. Use byte-offset reads with offset/limit, or increase the host max_scan_bytes setting."}}

          position ->
            offset = if position == :past_end, do: byte_size(bytes), else: position
            rest = binary_part(bytes, offset, byte_size(bytes) - offset)
            requested = line_end(rest, Map.get(args, "line_count", 200), 0)
            size = min(requested, args["limit"])
            content = binary_part(rest, 0, size)
            truncated = offset + size < byte_size(bytes) or more
            partial = size > 0 and :binary.last(content) != 10 and truncated
            byte_limit_truncated = requested > args["limit"]

            lines =
              length(:binary.matches(content, "\n")) +
                if(size > 0 and :binary.last(content) != 10, do: 1, else: 0)

            metadata = %{
              range_unit: "lines",
              start_line: start,
              returned_lines: lines,
              returned_bytes: size,
              output_limit_bytes: args["limit"],
              byte_limit_truncated: byte_limit_truncated,
              offset: offset,
              next_offset: offset + size,
              next_line: if(truncated and not partial, do: start + lines, else: nil),
              partial_line: partial,
              truncated: truncated
            }

            metadata =
              if byte_limit_truncated do
                Map.put(
                  metadata,
                  :hint,
                  "The requested line range exceeded the output byte limit. limit counts bytes, not lines; use line_count to choose how many lines to read and omit limit for the host default or increase it within the allowed bound to return more text per line. To continue a partial line, read from next_offset in byte mode and omit start_line/line_count."
                )
              else
                metadata
              end

            {:ok, content, metadata}
        end
      end
    end
  end

  defp read(_path, %{"line_count" => _}, _opts),
    do:
      {:error,
       {:missing_start_line, "line_count requires start_line; limit is measured in bytes."}}

  defp read(path, args, _opts) do
    offset = args["offset"]
    limit = args["limit"]

    with {:ok, bytes} <- Alto.BoundedFile.range(path, offset, limit + 1) do
      size = min(byte_size(bytes), limit)

      {:ok, binary_part(bytes, 0, size),
       %{
         range_unit: "bytes",
         offset: offset,
         next_offset: offset + size,
         truncated: byte_size(bytes) > limit
       }}
    end
  end

  defp line_offset(_bytes, 0, offset), do: offset

  defp line_offset(bytes, count, offset) do
    case :binary.match(bytes, "\n") do
      {index, 1} ->
        step = index + 1
        line_offset(binary_part(bytes, step, byte_size(bytes) - step), count - 1, offset + step)

      :nomatch ->
        :past_end
    end
  end

  defp line_end(_bytes, 0, offset), do: offset

  defp line_end(bytes, count, offset) do
    case :binary.match(bytes, "\n") do
      {index, 1} ->
        step = index + 1
        line_end(binary_part(bytes, step, byte_size(bytes) - step), count - 1, offset + step)

      :nomatch ->
        offset + byte_size(bytes)
    end
  end
end
