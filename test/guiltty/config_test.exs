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

  test "the window, cursor, shell and behavior settings", %{tmp_dir: dir} do
    path =
      write(dir, "more.exs", """
      [
        cursor: [style: :bar, blink: true],
        window: [padding: 10, columns: 120, rows: 40, opacity: 0.85],
        shell: [command: "/bin/bash", args: ["-l"]],
        working_directory: "~/src",
        copy_on_select: :clipboard,
        wheel_lines: 5,
        bold_is_bright: false
      ]
      """)

    assert {:ok, c} = Config.load(path)
    assert c.cursor == %{style: :bar, blink: true}
    assert c.window == %{padding: 10, columns: 120, rows: 40, opacity: 0.85}
    assert c.shell == %{command: "/bin/bash", args: ["-l"]}
    assert c.working_directory == Path.expand("~/src")
    assert {c.copy_on_select, c.wheel_lines, c.bold_is_bright} == {:clipboard, 5, false}
    assert c.keys.open_config == ["ctrl+,"]
  end

  test "a named theme, alone or as the base for changes", %{tmp_dir: dir} do
    assert {:ok, %{theme: dracula}} = Config.load(write(dir, "a.exs", ~s([theme: "dracula"])))
    assert dracula.bg == {0x28, 0x2A, 0x36}

    assert {:ok, %{theme: theme}} =
             Config.load(write(dir, "b.exs", ~s([theme: [name: "dracula", bg: "#000000"]])))

    assert theme.bg == {0, 0, 0} and theme.fg == dracula.fg
    assert {:error, msg} = Config.load(write(dir, "c.exs", ~s([theme: "nope"])))
    assert msg =~ "gruvbox-dark"
  end

  test "bad values in the new settings are reported", %{tmp_dir: dir} do
    for bad <- [
          "[cursor: [style: :beam]]",
          "[window: [opacity: 0]]",
          "[window: [padding: -1]]",
          "[shell: [command: 42]]",
          "[working_directory: \"relative\"]",
          "[wheel_lines: 0]",
          "[copy_on_select: :maybe]"
        ] do
      assert {:error, _} = Config.load(write(dir, "bad.exs", bad)), bad
    end
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
