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
        bold_is_bright: false,
        tab_bar: :bottom
      ]
      """)

    assert {:ok, c} = Config.load(path)
    assert c.cursor == %{style: :bar, blink: true}
    assert c.window == %{padding: 10, columns: 120, rows: 40, opacity: 0.85}
    assert c.shell == %{command: "/bin/bash", args: ["-l"]}
    assert c.working_directory == Path.expand("~/src")
    assert {c.copy_on_select, c.wheel_lines, c.bold_is_bright} == {:clipboard, 5, false}
    assert c.tab_bar == :bottom
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
          "[copy_on_select: :maybe]",
          "[tab_bar: :left]"
        ] do
      assert {:error, _} = Config.load(write(dir, "bad.exs", bad)), bad
    end
  end

  test "a misspelled name is reported, with a suggestion", %{tmp_dir: dir} do
    assert {:error, "unknown setting :curser (did you mean :cursor?)"} =
             Config.load(write(dir, "a.exs", "[curser: [style: :bar]]"))

    assert {:error, "window: unknown name :opacty (did you mean :opacity?)"} =
             Config.load(write(dir, "b.exs", "[window: [opacty: 0.9]]"))

    assert {:error, "keys: unknown name :new_tba (did you mean :new_tab?)"} =
             Config.load(write(dir, "c.exs", ~s([keys: [new_tba: ["ctrl+t"]]])))

    assert {:error, "unknown setting :zzz"} = Config.load(write(dir, "d.exs", "[zzz: 1]"))
  end

  # The safety net for new settings: every one must have a check. A setting
  # added to the defaults without one fails here, instead of letting a bad
  # value through to whatever uses it.
  test "every setting rejects a value of the wrong shape", %{tmp_dir: dir} do
    for {name, _default} <- Config.defaults() do
      path = write(dir, "#{name}.exs", "[#{name}: {:not, :valid}]")
      assert {:error, _} = Config.load(path), "#{name} accepted {:not, :valid}"
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

  test "a broken edit keeps the previous config and says why, until it's fixed", %{
    tmp_dir: dir
  } do
    path = write(dir, "live.exs", "[theme: [bg: \"#000001\"]]")
    pid = start_supervised!({Config, path: path, name: nil})
    GenServer.call(pid, {:subscribe, self()})

    File.write!(path, "[\n  theme: \"drakula\"\n]")
    File.touch!(path, System.os_time(:second) + 5)
    assert_receive {:config_error, "live.exs: theme: unknown name \"drakula\"" <> _}, 3000
    assert GenServer.call(pid, :get).theme.bg == {0, 0, 1}

    # A window that opens now hears about it right away.
    GenServer.call(pid, {:subscribe, self()})
    assert_receive {:config_error, "live.exs: " <> _}

    File.write!(path, "[theme: \"dracula\"]")
    File.touch!(path, System.os_time(:second) + 10)
    assert_receive {:config, %{theme: %{bg: {0x28, 0x2A, 0x36}}}}, 3000
  end

  test "errors in the file say which line", %{tmp_dir: dir} do
    assert {:error, "/" <> _ = syntax} =
             Config.load(write(dir, "s.exs", "[\n  font: [size: 16,\n"))

    assert syntax =~ ~r/s\.exs:\d+: /

    runtime = write(dir, "r.exs", "x = 1\n[\n  font: [size: x + \"a\"]\n]\n")
    assert {:error, message} = Config.load(runtime)
    assert message =~ "r.exs:3: bad argument in arithmetic expression"
  end
end
