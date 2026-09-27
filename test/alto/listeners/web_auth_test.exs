defmodule Alto.Listeners.WebAuthTest do
  use ExUnit.Case, async: true
  alias Alto.Listeners.WebAuth

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

    refute WebAuth.allowed?(
             conn
             |> Plug.Conn.put_req_header("authorization", "Bearer " <> token)
             |> Plug.Conn.put_req_header("sec-websocket-protocol", "alto-auth." <> token),
             auth
           )

    assert {:error, _} = WebAuth.normalize({:token, "short"})
  end

  test "hosts can replace authentication or explicitly select a trusted transport" do
    conn = Plug.Test.conn(:get, "/ws")
    value = "host-value"

    authenticate = fn conn ->
      if Plug.Conn.get_req_header(conn, "x-host-auth") == [value],
        do: :ok,
        else: {:error, :denied}
    end

    {:ok, {auth, nil}} = WebAuth.normalize(authenticate)
    refute WebAuth.allowed?(conn, auth)
    assert WebAuth.allowed?(Plug.Conn.put_req_header(conn, "x-host-auth", "host-value"), auth)

    for authenticate <- [
          fn _ -> raise "verifier unavailable" end,
          fn _ -> throw(:unavailable) end,
          fn _ -> exit(:unavailable) end,
          fn _ -> true end
        ] do
      {:ok, {broken, nil}} = WebAuth.normalize(authenticate)
      refute WebAuth.allowed?(conn, broken)
    end

    assert {:ok, {:none, nil}} = WebAuth.normalize(:none)
    assert WebAuth.allowed?(conn, :none)
  end
end
