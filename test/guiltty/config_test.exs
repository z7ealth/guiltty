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
    # The tab bar sits below the terminal unless the config says :top.
    assert config.tab_bar == :bottom
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
        tab_bar: :top
      ]
      """)

    assert {:ok, c} = Config.load(path)
    assert c.cursor == %{style: :bar, blink: true}
    assert c.window == %{padding: 10, columns: 120, rows: 40, opacity: 0.85}
    assert c.shell == %{command: "/bin/bash", args: ["-l"]}
    assert c.working_directory == Path.expand("~/src")
    assert {c.copy_on_select, c.wheel_lines, c.bold_is_bright} == {:clipboard, 5, false}
    assert c.tab_bar == :top
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

  test "every built-in theme loads, with 16 colors" do
    assert length(Guiltty.Theme.names()) == 10

    for name <- Guiltty.Theme.names() do
      assert {:ok, theme} = Guiltty.Theme.named(name)
      assert length(theme.ansi) == 16, name
    end
  end

  test "the guiltty theme brings its own accent, and yours wins", %{tmp_dir: dir} do
    lavender = {0x91, 0x84, 0xD9}
    assert {:ok, %{theme: theme}} = Config.load(write(dir, "a.exs", ~s([theme: "guiltty"])))
    assert theme.bg == {0x0D, 0x11, 0x17}
    assert theme.tab_accent == lavender and theme.pane_border_active == lavender
    # Other themes leave them to the renderer.
    assert {:ok, nord} = Guiltty.Theme.named("nord")
    assert nord.tab_accent == nil

    assert {:ok, %{theme: mine}} =
             Config.load(
               write(dir, "b.exs", ~s([theme: [name: "guiltty", tab_accent: "#ff0000"]]))
             )

    assert mine.tab_accent == {0xFF, 0, 0} and mine.pane_border_active == lavender
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

  test "the AI tool: its command and where it opens", %{tmp_dir: dir} do
    assert {:ok, %{ai: %{command: nil, position: :right}}} =
             Config.load(write(dir, "a.exs", "[]"))

    assert {:ok, %{ai: %{command: "my-ai-tool", position: :tab}}} =
             Config.load(write(dir, "b.exs", ~s([ai: [command: "my-ai-tool", position: :tab]])))

    assert {:error, "ai position" <> _} =
             Config.load(write(dir, "c.exs", "[ai: [position: :left]]"))

    assert {:error, "ai:" <> _} = Config.load(write(dir, "d.exs", "[ai: [command: 5]]"))
    assert {:error, "ai:" <> _} = Config.load(write(dir, "e.exs", ~s([ai: [command: "  "]])))
  end

  test "tab styles, and tab colors in the theme, also from a named one", %{tmp_dir: dir} do
    # The default (guiltty) sets its accent, and leaves the bar to the renderer.
    assert {:ok, %{tab_style: :flat, theme: %{tab_accent: {0x91, 0x84, 0xD9}, tab_bar: nil}}} =
             Config.load(write(dir, "a.exs", "[]"))

    assert {:ok, %{tab_style: :powerline, theme: theme}} =
             Config.load(
               write(dir, "b.exs", """
               [tab_style: :powerline,
                theme: [name: "dracula", tab_bar: "#282a36", tab_accent: "#ff79c6"]]
               """)
             )

    assert theme.tab_bar == {0x28, 0x2A, 0x36}
    assert theme.tab_accent == {0xFF, 0x79, 0xC6}
    assert theme.tab_active == nil
    assert theme.bg == elem(Guiltty.Theme.named("dracula"), 1).bg

    assert {:error, msg} = Config.load(write(dir, "c.exs", "[tab_style: :fancy]"))
    assert msg =~ "tab_style"
    assert {:error, msg} = Config.load(write(dir, "d.exs", "[theme: [tab_active: \"pink\"]]"))
    assert msg =~ "tab_active"
    assert {:error, msg} = Config.load(write(dir, "e.exs", "[theme: [tab_activ: \"#ffffff\"]]"))
    assert msg =~ "did you mean :tab_active"
  end

  test "pane borders: style, thickness, and their colors in the theme", %{tmp_dir: dir} do
    # The default (guiltty) sets its own border colors.
    assert {:ok,
            %{
              pane_border: %{style: :solid, thickness: :thin},
              theme: %{pane_border: {0x30, 0x36, 0x3D}}
            }} =
             Config.load(write(dir, "a.exs", "[]"))

    assert {:ok, %{pane_border: %{style: :double, thickness: :thick}, theme: theme}} =
             Config.load(
               write(dir, "b.exs", """
               [pane_border: [style: :double, thickness: :thick],
                theme: [name: "dracula", pane_border: "#44475a", pane_border_active: "#bd93f9"]]
               """)
             )

    assert theme.pane_border == {0x44, 0x47, 0x5A}
    assert theme.pane_border_active == {0xBD, 0x93, 0xF9}

    assert {:error, msg} = Config.load(write(dir, "c.exs", "[pane_border: [style: :wavy]]"))
    assert msg =~ "pane_border style"
    assert {:error, msg} = Config.load(write(dir, "d.exs", "[pane_border: [width: 2]]"))
    assert msg =~ "pane_border"
    assert {:error, msg} = Config.load(write(dir, "e.exs", "[theme: [pane_border: \"grey\"]]"))
    assert msg =~ "pane_border"
  end

  test "the default keys work on US and Latin American layouts alike" do
    keys = Config.defaults().keys
    # Ctrl+Shift+H on any layout; the + key, where it has a key of its own.
    assert "ctrl+shift+h" in keys.cheatsheet
    assert "ctrl+plus" in keys.zoom_in
    assert Guiltty.Keymap.parse_key("ctrl+plus") == {:ok, {?+, MapSet.new([:ctrl])}}
    # "space" names the space bar: " " can't be written in a key name.
    # The laptop AI key sends Super+Shift+F23.
    assert keys.ai == ["ctrl+shift+space", "super+shift+f23"]

    assert Guiltty.Keymap.parse_key("ctrl+shift+space") ==
             {:ok, {?\s, MapSet.new([:ctrl, :shift])}}
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
