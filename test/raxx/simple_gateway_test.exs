defmodule Raxx.SimpleGatewayTest do
  use ExUnit.Case
  alias Raxx.SimpleGateway

  setup do
    {:ok, gateway} = SimpleGateway.start_link()
    {:ok, %{gateway: gateway}}
  end

  test "Request with no body is sent", %{gateway: gateway} do
    {port, listen_socket} = listen()

    request = Raxx.request(:GET, "http://localhost:#{port}/path?query")
    {:ok, _task} = SimpleGateway.async(request, gateway: gateway)

    {:ok, socket} = accept(listen_socket)
    {:ok, first_request} = receive_packet(socket)

    assert "GET /path?query HTTP/1.1\r\nhost: localhost:#{port}\r\nconnection: close\r\n\r\n" ==
             first_request
  end

  test "Request with complete body is sent", %{gateway: gateway} do
    {port, listen_socket} = listen()

    request =
      Raxx.request(:GET, "http://localhost:#{port}/")
      |> Raxx.set_body("Hello, Raxx!!")

    {:ok, _task} = SimpleGateway.async(request, gateway: gateway)

    {:ok, socket} = accept(listen_socket)
    {:ok, first_request} = receive_packet(socket)

    assert "GET / HTTP/1.1\r\nhost: localhost:#{port}\r\nconnection: close\r\ncontent-length: 13\r\n\r\nHello, Raxx!!" ==
             first_request
  end

  @tag :skip
  # until streaming supported
  test "Request with content length and body unavailable fails", %{gateway: _gateway} do
  end

  @tag :skip
  # until streaming supported
  test "Request with chunked body fails", %{gateway: _gateway} do
  end

  test "response with no body is delivered", %{gateway: gateway} do
    {port, listen_socket} = listen()

    request = Raxx.request(:GET, "http://localhost:#{port}/")
    {:ok, task} = SimpleGateway.async(request, gateway: gateway)
    monitor = Process.monitor(task.client)

    {:ok, socket} = accept(listen_socket)
    {:ok, _first_request} = receive_packet(socket)
    :ok = :gen_tcp.send(socket, "HTTP/1.1 200 OK\r\nfoo: bar\r\n\r\n")
    {:ok, response} = SimpleGateway.yield(task)
    assert response.status == 200
    assert response.headers == [{"foo", "bar"}]
    assert response.body == ""

    assert_receive {:DOWN, ^monitor, :process, _pid, :normal}
  end

  test "response with body in single packet is parsed", %{gateway: gateway} do
    {port, listen_socket} = listen()

    request = Raxx.request(:GET, "http://localhost:#{port}/")
    {:ok, task} = SimpleGateway.async(request, gateway: gateway)
    monitor = Process.monitor(task.client)

    {:ok, socket} = accept(listen_socket)
    {:ok, _first_request} = receive_packet(socket)
    :ok = :gen_tcp.send(socket, "HTTP/1.1 200 OK\r\ncontent-length: 12\r\n\r\nHello, Raxx!")
    {:ok, response} = SimpleGateway.yield(task)
    assert response.status == 200
    assert response.headers == [{"content-length", "12"}]
    assert response.body == "Hello, Raxx!"

    assert_receive {:DOWN, ^monitor, :process, _pid, :normal}
  end

  test "response sent over several packets is parsed", %{gateway: gateway} do
    {port, listen_socket} = listen()

    request = Raxx.request(:GET, "http://localhost:#{port}/")
    {:ok, task} = SimpleGateway.async(request, gateway: gateway)
    monitor = Process.monitor(task.client)

    {:ok, socket} = accept(listen_socket)
    {:ok, _first_request} = receive_packet(socket)
    packets = ["HTTP/1.1 20", "0 OK\r\nconten", "t-length: 12\r\n\r\nHel", "lo, Raxx!"]

    for packet <- packets do
      :ok = :gen_tcp.send(socket, packet)
      Process.sleep(100)
    end

    {:ok, response} = SimpleGateway.yield(task)
    assert response.status == 200
    assert response.headers == [{"content-length", "12"}]
    assert response.body == "Hello, Raxx!"

    assert_receive {:DOWN, ^monitor, :process, _pid, :normal}
  end

  @tag :skip
  # until streaming supported
  test "chunked response is an error", %{gateway: _gateway} do
    # TODO  support streaming
  end

  test "response to a HEAD request is processed correctly", %{gateway: gateway} do
    {port, listen_socket} = listen()

    request = Raxx.request(:HEAD, "http://localhost:#{port}/")
    {:ok, task} = SimpleGateway.async(request, gateway: gateway)
    monitor = Process.monitor(task.client)

    {:ok, socket} = accept(listen_socket)
    {:ok, _first_request} = receive_packet(socket)
    :ok = :gen_tcp.send(socket, "HTTP/1.1 200 OK\r\ncontent-length: 12\r\n\r\n")
    {:ok, response} = SimpleGateway.yield(task)
    assert response.status == 200
    assert response.headers == [{"content-length", "12"}]
    assert response.body == ""

    assert_receive {:DOWN, ^monitor, :process, _pid, :normal}
  end

  #
  # test "fails if second request is sent to client", %{gateway: gateway} do
  #   # should raise
  # end

  test "Connection lost during response line is reported to caller", %{gateway: gateway} do
    {port, listen_socket} = listen()

    request = Raxx.request(:GET, "http://localhost:#{port}/")
    {:ok, task} = SimpleGateway.async(request, gateway: gateway)
    monitor = Process.monitor(task.client)

    {:ok, socket} = accept(listen_socket)
    {:ok, _first_request} = receive_packet(socket)
    :ok = :gen_tcp.send(socket, "HTTP/1.1 20")
    :ok = :gen_tcp.close(socket)
    {:error, :interrupted} = SimpleGateway.yield(task)
    assert_receive {:DOWN, ^monitor, :process, _pid, :normal}
  end

  test "Connection lost during headers is reported to caller", %{gateway: gateway} do
    {port, listen_socket} = listen()

    request = Raxx.request(:GET, "http://localhost:#{port}/")
    {:ok, task} = SimpleGateway.async(request, gateway: gateway)
    monitor = Process.monitor(task.client)

    {:ok, socket} = accept(listen_socket)
    {:ok, _first_request} = receive_packet(socket)
    :ok = :gen_tcp.send(socket, "HTTP/1.1 200 OK\r\nconte")
    :ok = :gen_tcp.close(socket)
    {:error, :interrupted} = SimpleGateway.yield(task)
    assert_receive {:DOWN, ^monitor, :process, _pid, :normal}
  end

  test "Connection lost during content is reported to caller", %{gateway: gateway} do
    {port, listen_socket} = listen()

    request = Raxx.request(:GET, "http://localhost:#{port}/")
    {:ok, task} = SimpleGateway.async(request, gateway: gateway)
    monitor = Process.monitor(task.client)

    {:ok, socket} = accept(listen_socket)
    {:ok, _first_request} = receive_packet(socket)
    :ok = :gen_tcp.send(socket, "HTTP/1.1 200 OK\r\ncontent-length: 12\r\n\r\nHello, R")
    :ok = :gen_tcp.close(socket)
    {:error, :interrupted} = SimpleGateway.yield(task)
    assert_receive {:DOWN, ^monitor, :process, _pid, :normal}
  end

  @tag :skip
  test "Invalid response is returned to caller", %{gateway: gateway} do
    {port, listen_socket} = listen()

    request = Raxx.request(:GET, "http://localhost:#{port}/")
    {:ok, task} = SimpleGateway.async(request, gateway: gateway)
    monitor = Process.monitor(task.client)

    {:ok, socket} = accept(listen_socket)
    {:ok, _first_request} = receive_packet(socket)
    :ok = :gen_tcp.send(socket, "garbage\r\n")
    :ok = :gen_tcp.close(socket)
    {:error, :interrupted} = SimpleGateway.yield(task)
    assert_receive {:DOWN, ^monitor, :process, _pid, :normal}
  end

  test "error is reported to caller if client dies", %{gateway: gateway} do
    {port, listen_socket} = listen()

    request = Raxx.request(:GET, "http://localhost:#{port}/")
    {:ok, task} = SimpleGateway.async(request, gateway: gateway)
    monitor = Process.monitor(task.client)

    {:ok, socket} = accept(listen_socket)
    {:ok, _first_request} = receive_packet(socket)
    true = Process.exit(task.client, :shutdown)
    assert_receive {:DOWN, ^monitor, :process, _pid, :shutdown}
  end

  test "client exits if caller dies", %{gateway: gateway} do
    {port, listen_socket} = listen()
    test_pid = self()

    spawn(fn ->
      request = Raxx.request(:GET, "http://localhost:#{port}/")
      {:ok, task} = SimpleGateway.async(request, gateway: gateway)
      send(test_pid, {:task, task})
    end)

    task =
      receive do
        {:task, task} ->
          task
      end

    monitor = Process.monitor(task.client)

    {:ok, socket} = accept(listen_socket)
    {:ok, _first_request} = receive_packet(socket)
    assert_receive {:DOWN, ^monitor, :process, _pid, :normal}
  end

  test "Can send and receive over ssl", %{gateway: gateway} do
    {port, listen_socket} = listen(0, :ssl)

    request = Raxx.request(:GET, "https://localhost:#{port}/path?query")
    {:ok, _task} = SimpleGateway.async(request, gateway: gateway)

    {:ok, socket} = accept(listen_socket, :ssl)
    {:ok, first_request} = receive_packet(socket, :ssl)

    assert "GET /path?query HTTP/1.1\r\nhost: localhost:#{port}\r\nconnection: close\r\n\r\n" ==
             first_request
  end

  # Test closing SSL cz caller died
  # Test connection lost and triggering ssl_closed

  defp listen(port \\ 0, transport \\ :tcp)

  defp listen(port, :tcp) do
    {:ok, listen_socket} = :gen_tcp.listen(port, mode: :binary, packet: :raw, active: false)
    {:ok, port} = :inet.port(listen_socket)
    {port, listen_socket}
  end

  defp listen(port, :ssl) do
    {:ok, listen_socket} = :ssl.listen(port, mode: :binary, active: false)
    {:ok, {_, port}} = :ssl.sockname(listen_socket)
    {port, listen_socket}
  end

  defp accept(listen_socket, transport \\ :tcp)

  defp accept(listen_socket, :tcp) do
    :gen_tcp.accept(listen_socket, 1_000)
  end

  defp accept(listen_socket, :ssl) do
    case :ssl.transport_accept(listen_socket) do
      {:ok, socket} ->
        case :ssl.ssl_accept(socket) do
          :ok ->
            {:ok, {:ssl, socket}}

          {:error, :closed} ->
            {:error, :econnaborted}

          {:error, reason} ->
            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp receive_packet(socket, transport \\ :tcp)

  defp receive_packet(socket, :tcp) do
    :gen_tcp.recv(socket, 0, 1_000)
  end

  defp receive_packet(socket, :ssl) do
    :ssl.recv(socket, 0, 1_000)
  end
end
