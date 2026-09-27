defmodule AltoTUI.Build.RustlerPrecompiled do
  # rustler_precompiled 0.9.0 extracts over a live, memory-mapped NIF. Its
  # attempted unlink targets the .tar.gz name instead of the shared library.
  # Stage each file and rename it so rebuilds cannot truncate a running NIF.
  @extractor """
    defp extract_nif(archive, directory) do
      with :ok <- File.mkdir_p(directory),
           {:ok, files} <- :erl_tar.extract(archive, [:compressed, :memory]) do
        Enum.reduce_while(files, :ok, fn {name, contents}, :ok ->
          target = Path.join(directory, to_string(name))
          temporary = target <> ".\#{System.pid()}.\#{System.unique_integer([:positive])}"

          result =
            try do
              with :ok <- File.write(temporary, contents),
                   do: File.rename(temporary, target)
            after
              File.rm(temporary)
            end

          if result == :ok, do: {:cont, :ok}, else: {:halt, result}
        end)
      end
    end

  """

  def patch!(directory) do
    path = Path.join(directory, "lib/rustler_precompiled.ex")
    source = File.read!(path)

    unless String.contains?(source, @extractor) do
      replacements = [
        {"      File.rm(lib_file)",
         "      # Atomic replacement below preserves existing NIF mappings."},
        {":erl_tar.extract(cached_tar_gz, [:compressed, cwd: Path.dirname(lib_file)])",
         "extract_nif(cached_tar_gz, native_dir)"},
        {":erl_tar.extract({:binary, tar_gz}, [:compressed, cwd: Path.dirname(lib_file)])",
         "extract_nif({:binary, tar_gz}, native_dir)"},
        {"  defp checksum_map(nif_module)", @extractor <> "  defp checksum_map(nif_module)"}
      ]

      patched =
        Enum.reduce(replacements, source, fn {old, new}, text ->
          unless length(:binary.matches(text, old)) == 1,
            do: raise("rustler_precompiled changed; review Alto's atomic NIF extraction patch")

          String.replace(text, old, new)
        end)

      File.write!(path, patched)
    end

    patched = File.read!(path)

    unless String.contains?(patched, "extract_nif(cached_tar_gz, native_dir)") and
             String.contains?(patched, "extract_nif({:binary, tar_gz}, native_dir)") and
             not String.contains?(patched, "File.rm(lib_file)"),
           do: raise("incomplete atomic NIF extraction patch")
  end

  def compile do
    directory = File.cwd!()
    patch!(directory)
    Mix.start()
    Mix.env(:prod)

    Mix.Project.in_project(:rustler_precompiled, directory, [deps_app_path: directory], fn _ ->
      Mix.Task.run("compile", [
        "--from-mix-deps-compile",
        "--no-deps-check",
        "--no-warnings-as-errors",
        "--no-code-path-pruning"
      ])
    end)
  end
end

if System.argv() == ["--compile"], do: AltoTUI.Build.RustlerPrecompiled.compile()
