defmodule Alto.Resource do
  @moduledoc """
  Trusted retained-resource capabilities used around owned child execution.

  Implementations own acquisition and capture policy. Execution owns deadlines,
  cancellation, child authority, checkpoint admission and uncertain outcomes.
  Resource implementations are selected by host configuration, never model input.
  """

  @callback prepare(struct(), Path.t()) :: {:ok, term()} | {:error, term()}
  @callback create(struct(), term(), term()) :: {:ok, map()} | {:error, term()}
  @callback use(struct(), binary(), non_neg_integer(), (map() -> term())) :: term()
  @callback resume(struct(), binary(), non_neg_integer(), function(), function()) :: term()
  @callback freeze(struct(), binary(), non_neg_integer()) :: {:ok, map()} | {:error, term()}
  @callback get(struct(), binary()) :: {:ok, map()} | {:error, term()}
  @callback resource_identity(struct()) :: {:ok, map()} | {:error, term()}

  def implementation?(%module{}) do
    Code.ensure_loaded?(module) and
      __MODULE__ in (module.module_info(:attributes)
                     |> Keyword.get_values(:behaviour)
                     |> List.flatten())
  end

  def implementation?(_), do: false
  def validate(nil), do: {:ok, nil}

  def validate(resource) do
    if implementation?(resource),
      do: {:ok, resource},
      else: {:error, "expected a retained-resource implementation"}
  end

  def prepare(%module{} = resource, cwd), do: module.prepare(resource, cwd)

  def create(%module{} = resource, snapshot, identity),
    do: module.create(resource, snapshot, identity)

  def use(%module{} = resource, id, revision, execute),
    do: module.use(resource, id, revision, execute)

  def resume(%module{} = resource, id, revision, admit, execute),
    do: module.resume(resource, id, revision, admit, execute)

  def freeze(%module{} = resource, id, revision), do: module.freeze(resource, id, revision)
  def get(%module{} = resource, id), do: module.get(resource, id)
  def identity(%module{} = resource), do: module.resource_identity(resource)
end
