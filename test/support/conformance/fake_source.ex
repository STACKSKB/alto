defmodule Alto.Conformance.FakeSource do
  @moduledoc """
  Deterministic fake webhook source for failure conformance.

  A pure delivery generator: no processes, no network, no authority. It
  builds the same bytes a real sender would sign (raw body + HMAC-SHA256
  base64, the `Alto.Listeners.Webhook` contract) so fixtures exercise the
  decided admission contract (`Alto.Queue.admit/3` under
  `"endpoint-path:delivery-id"` keys, first-wins, bounded completed window)
  without choosing any new isolation, retry, or compensation semantics.

  Randomness is seeded and recorded: `generate/3` derives every duplicate,
  reorder, and conflicting body from the given integer seed via `:rand`, so
  a failing sequence reproduces exactly from its seed. Callers log the seed
  (the sequence runner does this automatically).
  """

  @type delivery :: %{
          path: String.t(),
          delivery_id: String.t(),
          key: String.t(),
          body: String.t(),
          signature: String.t()
        }

  @doc "Sign a raw body the way the webhook ingress verifies it."
  @spec sign(binary(), String.t()) :: String.t()
  def sign(secret, body) when is_binary(secret) and is_binary(body) do
    Base.encode64(:crypto.mac(:hmac, :sha256, secret, body))
  end

  @doc "Build one signed delivery. The admission key is namespaced by endpoint."
  @spec delivery(String.t(), String.t(), String.t(), binary()) :: delivery()
  def delivery(path, delivery_id, secret, body)
      when is_binary(path) and is_binary(delivery_id) and is_binary(body) do
    %{
      path: path,
      delivery_id: delivery_id,
      key: path <> ":" <> delivery_id,
      body: body,
      signature: sign(secret, body)
    }
  end

  @doc """
  Generate `count` deliveries deterministically from `seed`.

  Options:

    * `:path` — endpoint path prefix (default `"/hooks/events"`);
    * `:secret` — HMAC secret (default `"conformance-secret"`);
    * `:duplicate_rate` — fraction of extra redeliveries, 0.0–1.0
      (default 0.3; redeliveries reuse the key, half with a conflicting body);
    * `:reorder` — when true (default), shuffle the final list with the
      seeded RNG to model reordered arrivals.

  Returns `{deliveries, seed}` so the seed travels with the sequence.
  """
  @spec generate(integer(), pos_integer(), keyword()) :: {[delivery()], integer()}
  def generate(seed, count, opts \\ [])
      when is_integer(seed) and is_integer(count) and count >= 1 do
    path = Keyword.get(opts, :path, "/hooks/events")
    secret = Keyword.get(opts, :secret, "conformance-secret")
    duplicate_rate = Keyword.get(opts, :duplicate_rate, 0.3)
    reorder? = Keyword.get(opts, :reorder, true)

    :rand.seed(:exsss, {seed, seed + 1, seed + 2})

    base =
      for n <- 1..count do
        body = JSON.encode!(%{"job" => n, "total" => n * 100})
        delivery(path, "del-#{n}", secret, body)
      end

    extras =
      base
      |> Enum.filter(fn _ -> :rand.uniform() < duplicate_rate end)
      |> Enum.map(fn d ->
        if :rand.uniform() < 0.5 do
          # Same bytes redelivered (sender retry).
          d
        else
          # Same delivery id, conflicting body: first-wins keeps the original.
          %{d | body: d.body <> " ", signature: sign(secret, d.body <> " ")}
        end
      end)

    deliveries = base ++ extras
    deliveries = if reorder?, do: shuffle(deliveries), else: deliveries
    {deliveries, seed}
  end

  @doc "Admit a delivery through the decided contract (insert-only, first-wins)."
  @spec admit(GenServer.server(), delivery(), term()) ::
          {:ok, map()} | {:error, :duplicate | {:key_claimed, binary()} | term()}
  def admit(queue, %{key: key, body: body}, payload_override \\ nil) do
    payload = payload_override || %{"delivery_id" => key, "body" => body}
    Alto.Queue.admit(queue, key, payload)
  end

  defp shuffle(list) do
    list
    |> Enum.map(&{:rand.uniform(), &1})
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.map(&elem(&1, 1))
  end
end
