defmodule Alto.Command.Executors.Bubblewrap do
  @moduledoc """
  Linux namespace executor with an isolated filesystem and optional network.

  Bubblewrap provides namespace and filesystem isolation here; it does not
  provide seccomp syscall filtering.
  """

  @behaviour Alto.Command.Executor

  alias Alto.Command.Executors.Unsandboxed
  alias Alto.Command.Invocation

  defmodule Execution do
    @moduledoc false

    @enforce_keys [:invocation, :sandbox]
    defstruct [:invocation, :sandbox]
  end

  @default_path "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
  @system_paths ["/usr", "/etc"]
  @reserved_destinations ["/usr", "/etc", "/proc", "/dev", "/tmp"]

  @impl true
  def prepare(%Invocation{} = invocation, opts) do
    with {:ok, bubblewrap} <- resolve_bubblewrap(opts),
         {:ok, network} <- validate_network(Keyword.get(opts, :network, :disabled)),
         {:ok, workspace_mode} <-
           validate_workspace_mode(Keyword.get(opts, :workspace, :read_write)),
         {:ok, read_only_paths} <- paths_option(opts, :read_only_paths),
         {:ok, writable_paths} <- paths_option(opts, :writable_paths),
         {:ok, protected_paths} <- protected_paths(invocation.cwd, opts),
         {:ok, environment} <- environment(Keyword.get(opts, :env, %{})) do
      arguments =
        namespace_args(network) ++
          system_mount_args() ++
          ["--proc", "/proc", "--dev", "/dev", "--tmpfs", "/tmp"] ++
          directory_args("/tmp/alto-home") ++
          mount_args(invocation.cwd, invocation.cwd, workspace_mode) ++
          Enum.flat_map(read_only_paths, &mount_args(&1, &1, :read_only)) ++
          Enum.flat_map(writable_paths, &mount_args(&1, &1, :read_write)) ++
          Enum.flat_map(protected_paths, &protect_args/1) ++
          ["--chdir", invocation.cwd, "--clearenv"] ++
          environment_args(environment) ++
          ["--", invocation.executable | invocation.args]

      wrapped = %Invocation{
        invocation
        | requested_program: bubblewrap,
          executable: bubblewrap,
          args: arguments,
          cwd: "/"
      }

      approval_details = %{
        backend: :bubblewrap,
        bubblewrap: bubblewrap,
        network: network,
        workspace: workspace_mode,
        read_only_paths: read_only_paths,
        writable_paths: writable_paths,
        protected_paths: protected_paths,
        environment_variables: environment |> Map.keys() |> Enum.sort()
      }

      sandbox = Map.take(approval_details, [:backend, :network, :workspace])
      {:ok, %Execution{invocation: wrapped, sandbox: sandbox}, approval_details}
    end
  end

  @impl true
  def execute(%Execution{invocation: invocation, sandbox: sandbox}) do
    case Unsandboxed.execute(invocation) do
      {:ok, result} -> {:ok, Map.put(result, :sandbox, sandbox)}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def open(%Execution{invocation: invocation}, opts) do
    # Target environment is fixed by prepare/2 inside --clearenv. A stdio host
    # cannot inject new environment authority after preparation.
    if Keyword.get(opts, :env, %{}) == %{},
      do: Unsandboxed.open(invocation, Keyword.delete(opts, :env)),
      else: {:error, :configure_environment_on_executor}
  end

  defp resolve_bubblewrap(opts) do
    case Keyword.get(opts, :bubblewrap) || System.find_executable("bwrap") do
      path when is_binary(path) ->
        expanded = Path.expand(path)

        case File.stat(expanded) do
          {:ok, %{type: :regular, mode: mode}} when Bitwise.band(mode, 0o111) != 0 ->
            {:ok, expanded}

          _other ->
            {:error, {:bubblewrap_not_executable, path}}
        end

      nil ->
        {:error, :bubblewrap_not_found}

      other ->
        {:error, {:invalid_bubblewrap, other}}
    end
  end

  defp validate_network(network) when network in [:disabled, :inherit], do: {:ok, network}
  defp validate_network(other), do: {:error, {:invalid_network_mode, other}}

  defp validate_workspace_mode(mode) when mode in [:read_only, :read_write], do: {:ok, mode}
  defp validate_workspace_mode(other), do: {:error, {:invalid_workspace_mode, other}}

  defp paths_option(opts, key) do
    paths = Keyword.get(opts, key, [])

    if is_list(paths) and Enum.all?(paths, &valid_mount_path?/1) do
      {:ok, Enum.map(paths, &Path.expand/1)}
    else
      {:error, {:invalid_mount_paths, key, paths}}
    end
  end

  defp valid_mount_path?(path) when is_binary(path) do
    Path.type(path) == :absolute and File.exists?(path)
  end

  defp valid_mount_path?(_path), do: false

  # Apply protected workspace mounts last; ordinary writable mounts must not
  # override them. Absent paths have no existing metadata to protect.
  defp protected_paths(cwd, opts) do
    paths = Keyword.get(opts, :protected_paths, [])

    if is_list(paths) do
      Alto.Result.reduce(paths, [], fn path, acc ->
        with true <- is_binary(path) and Path.type(path) == :relative and path != ".",
             {:ok, resolved} <- Alto.Tools.Path.resolve(path, cwd),
             true <- resolved != Path.expand(cwd),
             true <- resolved == Path.expand(path, cwd),
             {:ok, stat} <- File.lstat(resolved) do
          if stat.type in [:regular, :directory],
            do: {:ok, [resolved | acc]},
            else: {:error, {:invalid_protected_path, path}}
        else
          {:error, :enoent} ->
            {:ok, acc}

          _ ->
            {:error, {:invalid_protected_path, path}}
        end
      end)
      |> case do
        {:ok, paths} -> {:ok, Enum.reverse(paths)}
        error -> error
      end
    else
      {:error, {:invalid_protected_paths, paths}}
    end
  end

  defp protect_args(path) do
    ["--ro-bind", path, path]
  end

  defp environment(extra) when is_map(extra), do: environment(Map.to_list(extra))

  defp environment(extra) when is_list(extra) do
    base = %{"HOME" => "/tmp/alto-home", "LANG" => "C.UTF-8", "PATH" => @default_path}

    Alto.Result.reduce(extra, base, fn
      {name, value}, environment
      when is_binary(name) and is_binary(value) and name != "" ->
        if String.contains?(name, ["=", <<0>>]) or String.contains?(value, <<0>>) do
          {:error, {:invalid_environment_entry, name}}
        else
          {:ok, Map.put(environment, name, value)}
        end

      entry, _acc ->
        {:error, {:invalid_environment_entry, entry}}
    end)
  end

  defp environment(other), do: {:error, {:invalid_environment, other}}

  defp namespace_args(network) do
    [
      "--unshare-user",
      "--unshare-pid",
      "--unshare-ipc",
      "--unshare-uts",
      "--unshare-cgroup",
      "--new-session",
      "--die-with-parent"
    ] ++ if(network == :disabled, do: ["--unshare-net"], else: [])
  end

  defp system_mount_args do
    Enum.flat_map(@system_paths, fn path ->
      if File.exists?(path), do: ["--ro-bind", path, path], else: []
    end) ++ symlink_args()
  end

  defp symlink_args do
    Enum.flat_map(
      [{"usr/bin", "/bin"}, {"usr/sbin", "/sbin"}, {"usr/lib", "/lib"}, {"usr/lib64", "/lib64"}],
      fn {target, link} ->
        if File.exists?(Path.join("/", target)), do: ["--symlink", target, link], else: []
      end
    )
  end

  defp mount_args(source, destination, mode) do
    bind = if mode == :read_only, do: "--ro-bind", else: "--bind"
    directory_args(Path.dirname(destination)) ++ [bind, source, destination]
  end

  defp directory_args(path) do
    path
    |> Path.expand()
    |> Path.split()
    |> Enum.drop(1)
    |> Enum.scan("/", &Path.join(&2, &1))
    |> Enum.reject(&(&1 in @reserved_destinations or under_system_bind?(&1)))
    |> Enum.flat_map(&["--dir", &1])
  end

  defp under_system_bind?(path),
    do: Enum.any?(@system_paths, &(&1 == path or String.starts_with?(path, &1 <> "/")))

  defp environment_args(environment) do
    environment
    |> Enum.sort_by(fn {name, _value} -> name end)
    |> Enum.flat_map(fn {name, value} -> ["--setenv", name, value] end)
  end
end
