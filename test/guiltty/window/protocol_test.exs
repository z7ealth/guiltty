defmodule Guiltty.Window.ProtocolTest do
  use ExUnit.Case, async: true

  alias Guiltty.Window.Protocol

  test "encodes setup" do
    assert Protocol.setup(80, 24) == <<2, 0, 80, 0, 24>>
  end

  test "encodes rows and the cursor" do
    bin = IO.iodata_to_binary(Protocol.rows([{0, "ab"}, {23, "c"}], {1, 2}))
    assert bin == <<3, 0, 1, 0, 2, 0, 2, 0, 0, 0, 2, "ab", 0, 23, 0, 1, "c">>
  end

  test "decodes renderer events" do
    assert Protocol.decode(<<1, 0, 1, 2, "gl">>) == {:ok, {:hello, 1, "gl"}}
    assert Protocol.decode(<<4, "hé">>) == {:ok, {:text, "hé"}}
    assert Protocol.decode(<<5, 0, 0, 0, ?c, 0, 0x40>>) == {:ok, {:key, ?c, 0x40}}
    assert {:error, {:bad_message, _}} = Protocol.decode(<<99>>)
    assert {:error, {:bad_message, _}} = Protocol.decode(<<1, 0, 1, 5, "gl">>)
  end
end
