defmodule Alto.Image.Processor do
  @moduledoc """
  Optional image-resize backend used by `Alto.Tools.ReadImage`.

  Alto does not install or invoke an image library or shell command by default.
  A configured backend receives already bounded PNG or JPEG bytes and exact
  target dimensions. It must return encoded PNG/JPEG bytes; the reader sniffs
  and revalidates the result before exposing it to a model.
  """

  @callback resize(
              data :: binary(),
              media_type :: String.t(),
              width :: pos_integer(),
              height :: pos_integer(),
              opts :: keyword()
            ) :: {:ok, binary()} | {:error, term()}
end
