defmodule Raxx.SimpleGateway do
  @moduledoc """
  A simple HTTP/1.1 client.

  This client makes very few assumptions about the communications it sends.
  Each request is sent over a new connection, i.e. not HTTP/1.1 pipelining.

  This client has been developed in the context of test suites for Raxx server applications.
  For a more feature complete client try `HTTPoison`.

  ## Usage

  ### Start a gateway

  This can be a named process under the application supervision tree

      children = [
        {Raxx.SimpleGateway, [name: Raxx.SimpleGateway]}
      ]

  Or gateways can be started on demand.

      {:ok, pid} = Raxx.SimpleGateway.start_link()

  ### Send a request via a running gateway

      {:ok, task1} = Raxx.SimpleGateway.async(request, gateway: pid)

      # Use the default gateway.
      {:ok, task2} = Raxx.SimpleGateway.async(request)

      {:ok, response1} = Raxx.SimpleGateway.yield(task1)
      {:ok, response2} = Raxx.SimpleGateway.yield(task2)

  ## Notes

  - Not built on top of Task because want to support streaming,
    of both requests and responses
  - Would like to extend the SimpleGateway in include default options.
    Including target ip and port so that dummy host values could be tested
  - Other names to consider instead of simple - frugal, basic, spartan, naive
  """

  @type task :: %{caller: pid(), reference: reference(), request: Raxx.Request.t(), client: pid}

  alias __MODULE__.Client

  @doc """
  Start a gateway process.

  Every request sent using `Raxx.SimpleGateway` must be sent using a gateway process.
  """
  @spec start_link(GenServer.options()) :: {:ok, pid}
  def start_link(options \\ []) do
    options = Keyword.merge([strategy: :one_for_one], options)
    DynamicSupervisor.start_link(options)
  end

  @doc """
  Make a request using a gateway.

  If gateway is unspecified this call will use `Raxx.SimpleGateway` as the process name.
  """
  @spec async(Raxx.Request.t(), list()) :: {:ok, task} | {:error, term}
  def async(request, options \\ []) do
    gateway = Keyword.get(options, :gateway, __MODULE__)

    case DynamicSupervisor.start_child(gateway, Client) do
      {:ok, client} ->
        reference = Process.monitor(client)
        task = %{caller: self(), reference: reference, request: request, client: client}

        case GenServer.call(client, {:async, task}) do
          {:ok, ^task} ->
            {:ok, task}

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  @doc """
  Await the response of an outstanding request.
  """
  @spec yield(task, non_neg_integer) :: {:ok, Raxx.Response.t()} | {:error, term}
  def yield(%{caller: caller, reference: reference, client: _client}, timeout \\ 5_000)
      when caller == self() do
    receive do
      {^reference, response} ->
        Process.demonitor(reference, [:flush])
        response

      {:DOWN, ^reference, _, _, reason} ->
        {:error, {:exit, reason}}
    after
      timeout ->
        {:error, :timeout}
    end
  end
end
