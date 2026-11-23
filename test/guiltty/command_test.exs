defmodule Guiltty.CommandTest do
  # parse/1 alone: what the words mean, before anything runs. Running
  # them is tested through the real client in launcher_test.exs.
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Guiltty.Command

  defp parsed(args) do
    {:ok, %{command: command, pane: pane}} = Command.parse(args)
    {command, pane}
  end

  test "a noun and its action" do
    assert parsed(~w(tab --new)) == {{:tab, :new, nil}, nil}
    assert parsed(~w(pane --split-down)) == {{:pane, :split_down, nil}, nil}
    assert parsed(~w(pane --zoom)) == {{:pane, :zoom, nil}, nil}
    assert parsed(~w(pane --read-only --pane 7)) == {{:pane, :read_only, nil}, 7}
    assert parsed(~w(window --list)) == {{:window, :list, nil}, nil}
    assert parsed(~w(theme --set nord)) == {{:theme, :set, "nord"}, nil}
    assert parsed(["--help"]) == {{:help, nil, nil}, nil}
  end

  test "arguments, also after =" do
    assert parsed(~w(tab --go 3)) == {{:tab, :go, 3}, nil}
    assert parsed(["tab", "--rename", "web server"]) == {{:tab, :rename, "web server"}, nil}
    assert parsed(["tab", "--rename=a=b"]) == {{:tab, :rename, "a=b"}, nil}
    assert parsed(["tab", "--rename", ""]) == {{:tab, :rename, ""}, nil}
    assert parsed(~w(pane --focus left)) == {{:pane, :focus, :left}, nil}
  end

  test "ai and tab-bar take the config's values" do
    assert parsed(["ai", "--set-command", "claude --continue"]) ==
             {{:ai, :set_command, "claude --continue"}, nil}

    assert parsed(~w(ai --set-position tab)) == {{:ai, :set_position, :tab}, nil}
    assert parsed(~w(tab-bar --set-position bottom)) == {{:tab_bar, :set_position, :bottom}, nil}
    assert parsed(~w(tab-bar --set-position=top)) == {{:tab_bar, :set_position, :top}, nil}
    assert parsed(~w(tab-bar --set-style rounded)) == {{:tab_bar, :set_style, :rounded}, nil}

    assert {:error, "ai --set-command takes a program" <> _} =
             Command.parse(["ai", "--set-command", " "])

    assert {:error, "ai --set-position takes down, right or tab"} =
             Command.parse(~w(ai --set-position left))

    assert {:error, "tab-bar --set-position takes bottom or top"} =
             Command.parse(~w(tab-bar --set-position side))

    assert {:error, "tab-bar --set-style takes flat, minimal, powerline, rounded or separators"} =
             Command.parse(~w(tab-bar --set-style round))
  end

  test "--pane goes anywhere, once" do
    assert parsed(~w(--pane 7 tab --close)) == {{:tab, :close, nil}, 7}
    assert parsed(~w(tab --close --pane=7)) == {{:tab, :close, nil}, 7}
    assert {:error, "--pane given twice"} = Command.parse(~w(--pane 7 tab --close --pane 8))
    assert {:error, "--pane takes" <> _} = Command.parse(~w(--pane seven tab --close))
    assert {:error, "--pane takes" <> _} = Command.parse(~w(tab --close --pane))
  end

  test "mistakes say what would be right" do
    assert {:error, "tab: say what to do: --new, --close" <> _} = Command.parse(["tab"])
    assert {:error, "tab has no --open: --new" <> _} = Command.parse(~w(tab --open))
    assert {:error, "tab --new takes nothing more (now?)"} = Command.parse(~w(tab --new now))
    assert {:error, "tab --go takes a tab's number" <> _} = Command.parse(~w(tab --go 0))
    assert {:error, "tab --go takes N"} = Command.parse(~w(tab --go))
    assert {:error, "pane --focus takes left, right" <> _} = Command.parse(~w(pane --focus in))
    assert {:error, "tab --rename takes one NAME" <> _} = Command.parse(~w(tab --rename a b))
    assert {:error, "no command \"stop\"" <> _} = Command.parse(["stop"])
    assert {:error, _} = Command.parse(["tab", "--rename", "\e[31m"])
    assert {:error, _} = Command.parse([])
  end

  test "theme names: the whole name, or the start of only one" do
    assert Command.theme_name("dracula") == {:ok, "dracula"}
    assert Command.theme_name("tok") == {:ok, "tokyo-night"}
    assert {:error, "catppuccin could be" <> _} = Command.theme_name("catppuccin")
    assert {:error, "no theme" <> _} = Command.theme_name("")
    assert {:error, "no theme" <> _} = Command.theme_name("neon")
  end

  test "help lists every command" do
    help = Enum.join(Command.help(), "\n")

    for words <- ["tab --new", "pane --split-right", "theme --set NAME", "window --list"],
        do: assert(help =~ "guiltty " <> words)
  end

  property "never raises, whatever it's given" do
    word =
      StreamData.one_of([
        StreamData.member_of(~w(tab pane window theme --new --go --pane --rename --focus left 3)),
        StreamData.string(:printable, max_length: 10),
        StreamData.binary(max_length: 10)
      ])

    check all(args <- StreamData.list_of(word, max_length: 6), max_runs: 1_000) do
      assert match?({:ok, _}, Command.parse(args)) or match?({:error, _}, Command.parse(args))
    end
  end
end
