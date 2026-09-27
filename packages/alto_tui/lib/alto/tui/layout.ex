defmodule Alto.TUI.Layout do
  @moduledoc "Responsive IRC-style pane geometry for the coding harness."

  alias ExRatatui.Layout.Rect

  @min_center 48
  @min_rail 20

  @type t :: %{
          root: Rect.t(),
          rail: Rect.t() | nil,
          transcript: Rect.t(),
          settings: Rect.t(),
          composer: Rect.t(),
          details: Rect.t() | nil,
          status: Rect.t(),
          left_seam: non_neg_integer() | nil
        }

  @doc "Calculate panes, collapsing the rail on narrow terminals."
  @spec calculate(non_neg_integer(), non_neg_integer(), keyword()) :: t()
  def calculate(width, height, opts \\ []) when width >= 0 and height >= 0 do
    root = rect(0, 0, width, height)
    status_height = if height > 0, do: 1, else: 0
    main_height = max(height - status_height, 0)
    status = rect(0, main_height, width, status_height)
    composer_height = min(if(main_height >= 18, do: 6, else: 4), main_height)
    settings_height = if main_height > composer_height, do: 1, else: 0
    content_height = max(main_height - composer_height - settings_height, 0)

    rail_requested = Keyword.get(opts, :rail_visible, true)
    requested_rail = clamp(Keyword.get(opts, :rail_width, 26), @min_rail, 48)

    rail? = rail_requested and width >= @min_center + @min_rail

    rail_width = if rail?, do: min(requested_rail, max(width - @min_center, @min_rail)), else: 0

    center_width = max(width - rail_width, 0)
    center_x = rail_width

    %{
      root: root,
      rail: if(rail?, do: rect(0, 0, rail_width, main_height)),
      transcript: rect(center_x, 0, center_width, content_height),
      settings: rect(center_x, content_height, center_width, settings_height),
      composer: rect(center_x, content_height + settings_height, center_width, composer_height),
      details: if(Keyword.get(opts, :details, false), do: rect(0, 0, width, main_height)),
      status: status,
      left_seam: if(rail?, do: rail_width - 1)
    }
  end

  @doc "Whether a screen coordinate lies inside a rectangle."
  @spec contains?(Rect.t() | nil, integer(), integer()) :: boolean()
  def contains?(nil, _x, _y), do: false

  def contains?(%Rect{} = rect, x, y) do
    x >= rect.x and y >= rect.y and x < rect.x + rect.width and y < rect.y + rect.height
  end

  defp rect(x, y, width, height), do: %Rect{x: x, y: y, width: width, height: height}
  defp clamp(value, low, high) when is_integer(value), do: value |> max(low) |> min(high)
  defp clamp(_value, low, _high), do: low
end
