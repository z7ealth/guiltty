defmodule Guiltty.ConfigTest do
  use ExUnit.Case, async: true

  alias Guiltty.Config

  @moduletag :tmp_dir

  defp write(dir, name, text) do
    path = Path.join(dir, name)
    File.write!(path, text)
    path
  end

  test "a full config is loaded and merged over the defaults", %{tmp_dir: dir} do
    path =
      write(dir, "config.exs", """
      [
        font: [family: "DejaVu Sans Mono", size: 20],
        theme: [bg: "#000010"],
        keys: [new_tab: ["ctrl+alt+n"]]
      ]
      """)

    assert {:ok, config} = Config.load(path)
    assert config.font == %{family: "DejaVu Sans Mono", size: 20}
    assert config.theme.bg == {0, 0, 16}
    assert config.theme.fg == Config.defaults().theme.fg
    assert config.keys.new_tab == ["ctrl+alt+n"]
    assert config.keys.close_tab == ["ctrl+shift+w"]
  end

  test "the example config is valid" do
    assert {:ok, _config} = Config.load(Path.expand("../../priv/config.example.exs", __DIR__))
  end

  test "mistakes are reported, not applied", %{tmp_dir: dir} do
    assert {:error, msg} = Config.load(write(dir, "a.exs", "[theme: [bg: \"blue\"]]"))
    assert msg =~ "bad color"
    assert {:error, _} = Config.load(write(dir, "b.exs", "[font: [size: 500]]"))
    assert {:error, _} = Config.load(write(dir, "c.exs", "%{not: :a_list}"))
    assert {:error, _} = Config.load(write(dir, "d.exs", "raise \"oops\""))
    assert {:error, _} = Config.load(write(dir, "e.exs", "[theme: [ansi: [\"#000000\"]]]"))
  end

  test "a change on disk is applied and sent to subscribers", %{tmp_dir: dir} do
    path = write(dir, "live.exs", "[theme: [bg: \"#000001\"]]")
    pid = start_supervised!({Config, path: path, name: nil})
    assert GenServer.call(pid, :get).theme.bg == {0, 0, 1}

    GenServer.call(pid, {:subscribe, self()})
    File.write!(path, "[theme: [bg: \"#000002\"]]")
    # The poll compares modification times, which have 1-second resolution.
    File.touch!(path, System.os_time(:second) + 5)
    assert_receive {:config, %{theme: %{bg: {0, 0, 2}}}}, 3000
  end

  test "a broken edit keeps the previous config", %{tmp_dir: dir} do
    path = write(dir, "live.exs", "[theme: [bg: \"#000001\"]]")
    pid = start_supervised!({Config, path: path, name: nil})
    File.write!(path, "[theme: [bg: ")
    File.touch!(path, System.os_time(:second) + 5)
    Process.sleep(1500)
    assert GenServer.call(pid, :get).theme.bg == {0, 0, 1}
  end
end
