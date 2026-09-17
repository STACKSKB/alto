defmodule Alto.Listeners.WebAuthTest do
  use ExUnit.Case, async: true
  alias Alto.Listeners.WebAuth

  defmodule HeaderAuth do
    @behaviour WebAuth
    def authorize(conn, opts) do
      if Plug.Conn.get_req_header(conn, "x-host-auth") == [opts[:value]],
        do: :ok,
        else: {:error, :denied}
    end
  end

  defmodule BrokenAuth do
    def authorize(_, _), do: raise("verifier unavailable")
  end

  test "generated tokens are unique and support bearer and browser credentials" do
    {:ok, {auth, token}} = WebAuth.normalize(:token)
    {:ok, {_, other}} = WebAuth.normalize(:token)
    refute token == other
    conn = Plug.Test.conn(:get, "/ws")
    refute WebAuth.allowed?(conn, auth)

    assert WebAuth.allowed?(
             Plug.Conn.put_req_header(conn, "authorization", "Bearer " <> token),
             auth
           )

    assert WebAuth.allowed?(
             Plug.Conn.put_req_header(
               conn,
               "sec-websocket-protocol",
               "alto.v1, alto-auth." <> token
             ),
             auth
           )

    refute WebAuth.allowed?(Plug.Conn.put_req_header(conn, "authorization", "Bearer wrong"), auth)
    assert {:error, _} = WebAuth.normalize({:token, "short"})
  end

  test "hosts can replace authentication or explicitly select a trusted transport" do
    conn = Plug.Test.conn(:get, "/ws")
    {:ok, {auth, nil}} = WebAuth.normalize({HeaderAuth, value: "host-value"})
    refute WebAuth.allowed?(conn, auth)
    assert WebAuth.allowed?(Plug.Conn.put_req_header(conn, "x-host-auth", "host-value"), auth)
    {:ok, {broken, nil}} = WebAuth.normalize({BrokenAuth, []})
    refute WebAuth.allowed?(conn, broken)
    assert {:ok, {:none, nil}} = WebAuth.normalize(:none)
    assert WebAuth.allowed?(conn, :none)
    assert {:error, _} = WebAuth.normalize({MissingAuth, []})
  end
end
