defmodule Alto.Contrib.Resident.Service do
  @moduledoc "Resident host. Client connections never own the lifetime of an Alto run."
  use Supervisor

  alias Alto.Contrib.Resident.Config

  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)

    Supervisor.start_link(__MODULE__, {Keyword.fetch!(opts, :config), name},
      name: component(name, :service)
    )
  end

  def start(%Config{} = config, opts \\ []) do
    DynamicSupervisor.start_child(
      Alto.Contrib.Resident.Services,
      {__MODULE__, [config: config] ++ opts}
    )
  end

  def stop(pid), do: DynamicSupervisor.terminate_child(Alto.Contrib.Resident.Services, pid)

  def registry(name \\ __MODULE__), do: component(name, :runtime)

  @impl true
  def init({%Config{} = config, name}) do
    with :ok <- Alto.Storage.ensure_private_dir(config.state_dir, owned: true) do
      children = config.runtime.children(config, name)

      Supervisor.init(children, strategy: :rest_for_one)
    else
      {:error, reason} -> {:stop, {:state_directory, reason}}
    end
  end

  @doc false
  def component(name, component),
    do: {:via, Registry, {Alto.Contrib.Resident.ProcessRegistry, {name, component}}}
end
