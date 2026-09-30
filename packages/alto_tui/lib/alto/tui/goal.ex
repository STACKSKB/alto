defmodule Alto.TUI.Goal do
  @moduledoc "Persistent task objectives managed through the gear menu."
  alias Alto.TUI.{App, Menu, State}
  alias Alto.Harness.Catalog

  def open(state) do
    task = State.selected_task(state)
    goal = task && task["goal"]
    actions = [{"[ Save goal ]", :save}]

    actions =
      if goal do
        toggle =
          if goal["status"] == "active", do: {"[ Pause ]", :pause}, else: {"[ Resume ]", :resume}

        actions ++
          [toggle] ++
          if(goal["status"] == "completed", do: [], else: [{"[ Complete ]", :complete}]) ++
          [{"[ Clear goal ]", :clear}]
      else
        actions
      end

    actions = actions ++ [{"[ Cancel ]", :cancel}]
    {buttons, actions} = Enum.unzip(actions)

    overlay =
      Menu.form(:goal, "task goal", [{:objective, "Objective", goal && goal["objective"], []}],
        on_action: &action/2,
        buttons: buttons,
        actions: actions,
        intro:
          if(goal,
            do: "Status: #{goal["status"]} · changes apply to the next run",
            else: "No goal set · save an objective for this task"
          ),
        hint: "Enter save · Tab actions · Esc cancel"
      )

    %{state | overlay: overlay, leader?: false, notice: nil}
  end

  def action(state, :cancel), do: %{state | overlay: nil}
  def action(state, :submit), do: action(state, :save)

  def action(state, :save) do
    objective = state.overlay |> Menu.value(:objective) |> String.trim()

    if objective == "" do
      %{state | overlay: %{state.overlay | error: "Enter an objective"}}
    else
      save(state, %{"objective" => objective, "status" => "active"})
    end
  end

  def action(state, :clear), do: save(state, nil)

  def action(state, action) when action in [:pause, :resume, :complete] do
    goal = State.selected_task(state)["goal"]
    status = %{pause: "paused", resume: "active", complete: "completed"}[action]
    save(state, Map.put(goal, "status", status))
  end

  defp save(state, goal) do
    with {:ok, state, task} <- App.ensure_task(state, (goal && goal["objective"]) || "Task"),
         {:ok, updated} <- Catalog.update_task(task["id"], %{"goal" => goal}, state.catalog_opts) do
      state
      |> State.update_task_record(updated)
      |> Map.merge(%{overlay: nil, notice: summary(updated) <> " · applies to the next run"})
    else
      {:error, reason} ->
        %{
          state
          | overlay: %{state.overlay | error: "Cannot save goal: #{App.human_error(reason)}"}
        }
    end
  end

  def summary(%{"goal" => %{"objective" => objective, "status" => status}}),
    do: "Goal (#{status}): #{objective}"

  def summary(_), do: "No goal set"

  def with_context(%{"goal" => %{"status" => "active", "objective" => objective}}, prompt),
    do: Alto.Content.prepend(prompt, "Task objective:\n#{objective}\n\nCurrent message:\n")

  def with_context(%{"goal" => %{"status" => status}}, prompt)
      when status in ["paused", "completed"],
      do:
        Alto.Content.prepend(
          prompt,
          "The persistent task objective is #{status}. Follow the current message rather than continuing the previous objective.\n\nCurrent message:\n"
        )

  def with_context(%{"goal" => nil}, prompt),
    do:
      Alto.Content.prepend(
        prompt,
        "The persistent task objective has been cleared.\n\nCurrent message:\n"
      )

  def with_context(_, prompt), do: prompt
end
