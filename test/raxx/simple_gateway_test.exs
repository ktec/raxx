defmodule Raxx.SimpleGatewayTest do
  use ExUnit.Case

  # TODO handle the connection close header
  setup do
    Raxx.SimpleGateway.start_link(name: Raxx.SimpleGateway)
    {:ok, %{}}
  end

  test "ss" do
    request = Raxx.request(:GET, "http://httpbin.org/get")

    {:ok, task} = Raxx.SimpleGateway.async(request)
    assert {:ok, response} = Raxx.SimpleGateway.yield(task)
    IO.inspect(response)

    request = Raxx.request(:HEAD, "http://httpbin.org/get")

    {:ok, task} = Raxx.SimpleGateway.async(request)
    assert {:ok, response} = Raxx.SimpleGateway.yield(task)
    IO.inspect(response)

    request = Raxx.request(:GET, "http://httpbin.org/drip")

    {:ok, task} = Raxx.SimpleGateway.async(request)
    assert {:ok, response} = Raxx.SimpleGateway.yield(task)
    IO.inspect(response)

    request = Raxx.request(:GET, "http://httpbin.org/drip?numbytes=0")

    {:ok, task} = Raxx.SimpleGateway.async(request)
    assert {:ok, response} = Raxx.SimpleGateway.yield(task)
    IO.inspect(response)

    request = Raxx.request(:GET, "http://httpbin.org/absolute-redirect/0")

    {:ok, task} = Raxx.SimpleGateway.async(request)
    assert {:ok, response} = Raxx.SimpleGateway.yield(task)
    IO.inspect(response)
  end
end
