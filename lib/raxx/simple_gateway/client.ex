defmodule Raxx.SimpleGateway.Client do
  @moduledoc false
  use GenServer

  @enforce_keys [:reference]
  defstruct @enforce_keys

  def child_spec([]) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, []},
      restart: :temporary
    }
  end

  def start_link() do
    GenServer.start_link(__MODULE__, nil, [])
  end

  @impl GenServer
  def init(nil) do
    {:ok, nil}
  end

  @impl GenServer
  def handle_call({:async, task}, _from, nil) do
    # monitor is the reference generated by this client for the caller.
    # reference is the reference the caller expects responses to be delivered with
    monitor = Process.monitor(task.caller)

    state = %{
      caller: task.caller,
      reference: task.reference,
      monitor: monitor,
      request: task.request,
      socket: nil,
      buffer: "",
      response: nil,
      body: nil
    }

    case Raxx.HTTP1.serialize_request(task.request, connection: :close) do
      {head, {:complete, body}} ->
        target =
          {task.request.scheme, :erlang.binary_to_list(Raxx.request_host(task.request)),
           Raxx.request_port(task.request)}

        data = [head, body]

        {:reply, {:ok, task}, state, {:continue, {:connect, target, data}}}
    end
  end

  @impl GenServer
  def handle_continue({:connect, target, data}, state) do
    options = [mode: :binary, packet: :raw, active: false]

    case connect(target, 1_000) do
      {:ok, socket} ->
        # NOTE assumes data is the full request
        :ok = send_data(socket, data)

        :ok = set_active(socket)
        state = %{state | socket: socket}
        {:noreply, state}
    end
  end

  @impl GenServer
  def handle_info(
        {transport, raw_socket, packet},
        state = %{socket: socket = {transport, raw_socket}, response: nil}
      )
      when transport in [:tcp, :ssl] do
    buffer = state.buffer <> packet

    case Raxx.HTTP1.parse_response(buffer) do
      {:ok, {response, _connection_status, body_read_state, rest}} ->
        case state.request.method do
          :HEAD ->
            response = %{response | body: ""}
            send(state.caller, {state.reference, {:ok, response}})

            state = %{state | response: response, body: :complete}
            {:stop, :normal, state}

          _ ->
            case body_read_state do
              {:bytes, content_length} ->
                state = %{state | response: response, body: {:bytes, content_length}}
                handle_info({:tcp, raw_socket, rest}, %{state | buffer: ""})

              {:complete, ""} ->
                response = %{response | body: ""}
                send(state.caller, {state.reference, {:ok, response}})

                state = %{state | response: response, body: :complete}
                {:stop, :normal, state}
            end
        end

      {:more, :undefined} ->
        state = %{state | buffer: buffer}
        :ok = set_active(socket)
        {:noreply, state}
    end
  end

  def handle_info(
        {transport, raw_socket, packet},
        state = %{socket: socket = {transport, raw_socket}, body: {:bytes, content_length}}
      )
      when transport in [:tcp, :ssl] do
    case state.buffer <> packet do
      <<body::binary-size(content_length), buffer::binary>> ->
        response = %{state.response | body: body}
        send(state.caller, {state.reference, {:ok, response}})

        state = %{state | body: :complete, buffer: buffer}
        {:stop, :normal, state}

      buffer ->
        state = %{state | buffer: buffer}
        :ok = set_active(socket)
        {:noreply, state}
    end
  end

  def handle_info({transport_closed, raw_socket}, state = %{socket: {_transport, raw_socket}})
      when transport_closed in [:tcp_closed, :ssl_closed] do
    send(state.caller, {state.reference, {:error, :interrupted}})

    {:stop, :normal, state}
  end

  def handle_info({:DOWN, monitor, :process, _pid, _reason}, state = %{monitor: monitor}) do
    :ok = close(state.socket)
    {:stop, :normal, state}
  end

  defp connect({:http, host, port}, timout) do
    options = [mode: :binary, packet: :raw, active: false]

    case :gen_tcp.connect(host, port, options, 1_000) do
      {:ok, raw_socket} ->
        {:ok, {:tcp, raw_socket}}

      other ->
        other
    end
  end

  defp connect({:https, host, port}, timout) do
    options = [mode: :binary, packet: :raw, active: false]

    case :ssl.connect(host, port, options, 1_000) do
      {:ok, raw_socket} ->
        {:ok, {:ssl, raw_socket}}

      other ->
        other
    end
  end

  defp set_active({:tcp, socket}) do
    :inet.setopts(socket, active: :once)
  end

  defp set_active({:ssl, socket}) do
    :ssl.setopts(socket, active: :once)
  end

  defp send_data({:tcp, socket}, message) do
    :gen_tcp.send(socket, message)
  end

  defp send_data({:ssl, socket}, message) do
    :ssl.send(socket, message)
  end

  defp close({:tcp, socket}) do
    :gen_tcp.close(socket)
  end

  defp close({:ssl, socket}) do
    :ssl.close(socket)
  end
end