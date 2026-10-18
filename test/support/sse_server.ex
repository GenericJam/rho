defmodule Rho.Test.SSEServer do
  @moduledoc """
  A model provider on a local port: answers each HTTP request with the
  next canned body as a server-sent-events stream, so a test runs
  req_llm's own streaming (its parsing, usage and pricing) without the
  network. Point req_llm at it with
  `Application.put_env(:req_llm, provider, base_url: url)`; each request's
  path comes to the test as `{Rho.Test.SSEServer, :request, path}`.
  """

  @doc "Serves `bodies`, one per request, under the test's supervisor; returns the base URL."
  @spec start!([String.t()]) :: String.t()
  def start!(bodies) do
    test = self()
    ExUnit.Callbacks.start_supervised!({Task, fn -> listen(test, bodies) end})
    assert_port()
  end

  defp assert_port do
    receive do
      {__MODULE__, :port, port} -> "http://127.0.0.1:#{port}"
    after
      5_000 -> raise "the SSE server didn't start"
    end
  end

  defp listen(test, bodies) do
    {:ok, socket} =
      :gen_tcp.listen(0, [:binary, packet: :raw, active: false, ip: {127, 0, 0, 1}])

    {:ok, port} = :inet.port(socket)
    send(test, {__MODULE__, :port, port})
    Enum.each(bodies, &answer(socket, test, &1))
  end

  defp answer(socket, test, body) do
    {:ok, conn} = :gen_tcp.accept(socket)
    {path, _request_body} = read_request(conn, "")
    send(test, {__MODULE__, :request, path})

    :ok =
      :gen_tcp.send(conn, [
        "HTTP/1.1 200 OK\r\ncontent-type: text/event-stream\r\n",
        "content-length: #{byte_size(body)}\r\nconnection: close\r\n\r\n",
        body
      ])

    :gen_tcp.close(conn)
  end

  defp read_request(conn, acc) do
    case :binary.split(acc, "\r\n\r\n") do
      [head, rest] ->
        [request_line | headers] = String.split(head, "\r\n")
        [_method, path | _] = String.split(request_line, " ")
        {path, read_body(conn, rest, content_length(headers))}

      [_partial] ->
        {:ok, data} = :gen_tcp.recv(conn, 0, 5_000)
        read_request(conn, acc <> data)
    end
  end

  defp content_length(headers) do
    Enum.find_value(headers, 0, fn header ->
      with [name, value] <- String.split(header, ":", parts: 2),
           "content-length" <- String.downcase(name) do
        value |> String.trim() |> String.to_integer()
      else
        _ -> nil
      end
    end)
  end

  defp read_body(_conn, body, length) when byte_size(body) >= length, do: body

  defp read_body(conn, body, length) do
    {:ok, data} = :gen_tcp.recv(conn, 0, 5_000)
    read_body(conn, body <> data, length)
  end
end
