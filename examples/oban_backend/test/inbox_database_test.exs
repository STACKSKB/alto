defmodule AltoObanExample.InboxDatabaseTest do
  use ExUnit.Case, async: false

  @moduletag :database

  alias AltoObanExample.{Inbox, InboxDelivery, Repo, Worker}

  test "event identity and its Oban job commit exactly once" do
    Repo.delete_all(InboxDelivery)
    Repo.delete_all(Oban.Job)

    opts = [repo: Repo, oban: Oban, worker: Worker, run: "event_flow"]
    payload = %{"delivery_id" => "database-1", "body" => ~s({"value": 42})}
    conflicting = %{"delivery_id" => "database-1", "body" => ~s({"value": 99})}

    assert {:ok, %Oban.Job{}} = Inbox.admit("/hooks/events:database-1", payload, opts)
    assert {:error, :duplicate} = Inbox.admit("/hooks/events:database-1", payload, opts)
    assert {:error, :duplicate} = Inbox.admit("/hooks/events:database-1", conflicting, opts)

    assert Repo.aggregate(InboxDelivery, :count) == 1
    assert Repo.aggregate(Oban.Job, :count) == 1
    assert %Oban.Job{args: %{"payload" => ^payload}} = Repo.one(Oban.Job)
  end
end
