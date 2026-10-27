defmodule GuilttyTest do
  use ExUnit.Case
  doctest Guiltty

  test "greets the world" do
    assert Guiltty.hello() == :world
  end
end
