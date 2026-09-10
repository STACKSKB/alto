#!/usr/bin/env elixir
Application.ensure_all_started(:alto)
Code.require_file("lib/workflow.ex", __DIR__)
Code.require_file("lib/webhook_inbox.ex", __DIR__)

report_result = fn result, label ->
  IO.inspect(result, label: label)
  unless match?({:ok, _}, result), do: System.halt(1)
end

case System.argv() do
  ["apply", repo, manifest, expected_hash] ->
    report_result.(
      RepositoryMaintenance.Workflow.apply_reviewed(repo, manifest, expected_hash),
      "apply"
    )

  [repo, report_path] ->
    case RepositoryMaintenance.Workflow.read_bounded(report_path, 64_000) do
      {:ok, body} ->
        case JSON.decode(body) do
          {:ok, report} when is_map(report) ->
            case RepositoryMaintenance.Workflow.prepare_state(repo) do
              {:ok, state_dir} ->
                {:ok, queue} =
                  Alto.Queue.start_link(
                    id: "repository-maintenance",
                    dir: Path.join(state_dir, "queue"),
                    name: :repository_maintenance_queue
                  )

                case RepositoryMaintenance.Workflow.admit(queue, report) do
                  {:ok, _} = admitted ->
                    IO.inspect(admitted, label: "admission")

                  {:error, :duplicate} ->
                    IO.puts("Report already admitted; checking recovery work")

                  error ->
                    report_result.(error, "admission")
                end

                report_result.(
                  RepositoryMaintenance.Workflow.process(queue, repo, state_dir: state_dir),
                  "workflow"
                )

              {:error, reason} ->
                IO.puts(:stderr, "unsafe state directory: #{inspect(reason)}")
                System.halt(1)
            end

          _ ->
            IO.puts(:stderr, "invalid report JSON")
            System.halt(1)
        end

      {:error, :file_too_large} ->
        IO.puts(:stderr, "report exceeds the 64000 byte limit")
        System.halt(1)

      {:error, reason} ->
        IO.puts(:stderr, "could not read report: #{inspect(reason)}")
        System.halt(1)
    end

  _ ->
    IO.puts(
      :stderr,
      "usage: mix run examples/repository_maintenance/run.exs REPOSITORY REPORT.json | " <>
        "apply REPOSITORY MANIFEST.json MANIFEST_SHA256"
    )

    System.halt(2)
end
