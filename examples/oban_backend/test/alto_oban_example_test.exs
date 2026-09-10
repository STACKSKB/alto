defmodule AltoObanExampleTest do
  use ExUnit.Case, async: false

  alias AltoObanExample.{Inbox, Repo, Worker}

  test "the adapter validates host wiring before the listener starts" do
    assert :ok =
             Alto.Inbox.validate_backend(Inbox,
               repo: Repo,
               oban: Oban,
               worker: Worker,
               run: "event_flow"
             )

    assert {:error, {:missing_inbox_options, [:run]}} =
             Alto.Inbox.validate_backend(Inbox,
               repo: Repo,
               oban: Oban,
               worker: Worker
             )
  end

  test "the Oban worker executes the named provider-less Alto run" do
    {:ok, _started} = Application.ensure_all_started(:alto)

    job = %Oban.Job{
      args: %{
        "delivery_key" => "/hooks/events:delivery-1",
        "run" => "event_flow",
        "payload" => %{"body" => ~s({"value": 42}), "delivery_id" => "delivery-1"}
      }
    }

    assert :ok = Worker.perform(job)
  end

  test "alto.exs selects the Oban inbox while retaining a named shallow run" do
    previous = System.get_env("WEBHOOK_SECRET")
    System.put_env("WEBHOOK_SECRET", "test-secret")

    on_exit(fn ->
      if previous,
        do: System.put_env("WEBHOOK_SECRET", previous),
        else: System.delete_env("WEBHOOK_SECRET")
    end)

    assert {:ok, config} = Alto.Config.load("alto.exs")
    options = Alto.Config.run_options(config)

    assert nil == options[:provider]
    assert %{"event_flow" => _run_options} = options[:runs]

    assert [{Alto.Listeners.Webhook, listener_opts}] = options[:listeners]
    assert [%{on_event: {:enqueue, {Inbox, inbox_opts}}}] = listener_opts[:endpoints]
    assert :ok = Alto.Inbox.validate_backend(Inbox, inbox_opts)
  end
end
