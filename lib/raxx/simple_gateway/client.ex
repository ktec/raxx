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

    case Raxx.HTTP1.serialize_request(task.request) do
      {head, {:complete, body}} ->
        target =
          {:erlang.binary_to_list(Raxx.request_host(task.request)),
           Raxx.request_port(task.request)}

        data = [head, body]

        {:reply, {:ok, task}, state, {:continue, {:connect, target, data}}}
    end
  end

  @impl GenServer
  def handle_continue({:connect, {host, port}, data}, state) do
    options = [mode: :binary, active: false]

    case :gen_tcp.connect(host, port, options, 1_000) do
      {:ok, socket} ->
        # NOTE assumes data is the full request
        :ok = :gen_tcp.send(socket, data)

        :inet.setopts(socket, active: :once)
        state = %{state | socket: socket}
        {:noreply, state}
    end
  end

  @impl GenServer
  def handle_info({:tcp, socket, packet}, state = %{socket: socket, response: nil}) do
    case Raxx.HTTP1.parse_response(packet) do
      {:ok, response, body_state, rest} ->
        case state.request.method do
          :HEAD ->
            response = %{response | body: ""}
            send(state.caller, {state.reference, {:ok, response}})

            state = %{state | response: response, body: :complete}
            {:stop, :normal, state}

          _ ->
            case body_state do
              {:bytes, content_length} ->
                state = %{state | response: response, body: {:bytes, content_length}}
                handle_info({:tcp, socket, rest}, state)

              {:complete, ""} ->
                response = %{response | body: ""}
                send(state.caller, {state.reference, {:ok, response}})

                state = %{state | response: response, body: :complete}
                handle_info({:tcp, socket, rest}, state)
            end
        end
    end
  end

  def handle_info(
        {:tcp, socket, packet},
        state = %{socket: socket, body: {:bytes, content_length}}
      ) do
    case state.buffer <> packet do
      <<body::binary-size(content_length), buffer::binary>> ->
        response = %{state.response | body: body}
        send(state.caller, {state.reference, {:ok, response}})

        state = %{state | body: :complete, buffer: buffer}
        {:stop, :normal, state}

      buffer ->
        state = %{state | buffer: buffer}
        {:noreply, state}
    end
  end
end
