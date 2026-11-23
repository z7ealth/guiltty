defmodule Guiltty.Command do
  @moduledoc """
  The `guiltty NOUN --ACTION` commands: what you, or a script, can ask the
  running guiltty to do from a shell. Book chapter 29.

      guiltty tab --new
      guiltty pane --split-right
      guiltty theme --set dracula
      guiltty ai --set-command claude
      guiltty tab-bar --set-position bottom
      guiltty window --list

  The C client (`c_src/client/guiltty.c`) sends its arguments as they
  are, over the launcher's socket (`Guiltty.Launcher`); this module is
  where they mean something. `parse/1` turns them into a command or an
  error to print, and never raises: what reaches the socket is checked
  here. `run/2` does it, through the same `Guiltty.Tabs` calls the keys
  use.

  ## Where "here" is

  Every shell guiltty starts has `GUILTTY_PANE`, its pane's id, and the
  client sends it along. So `guiltty pane --split-right` splits the pane
  you typed it in, and `guiltty tab --close` closes that tab, even when
  it's not the one on screen (a script in a background tab). `--pane ID`
  picks another pane (the ids `guiltty window --list` shows). With
  neither, as from a shell outside guiltty, the command goes to the
  window that last had the keyboard (`Guiltty.Lifeline.last_focused/0`),
  and its focused pane.

  A `GUILTTY_PANE` whose pane has closed (a tmux started in it, say) is
  an error, never a guess: `tab --close` on the wrong tab can't be undone.

  Commands that start a shell (`window --new`, `tab --new`,
  `pane --split-*`) print the new pane's id, for scripts:
  `id=$(guiltty tab --new)`.
  """

  alias Guiltty.{Config, Desk, Lifeline, Tabs, Theme}

  # {noun, [{flag, action, argument or nil, what it does}]}, in the order
  # help shows them.
  @commands [
    {"window", :window,
     [
       {"--new", :new, nil, "open a new window"},
       {"--list", :list, nil, "list the windows, their tabs and panes, with ids"}
     ]},
    {"tab", :tab,
     [
       {"--new", :new, nil, "open a tab after the active one"},
       {"--close", :close, nil, "close the tab, every pane in it"},
       {"--next", :next, nil, "go to the next tab"},
       {"--prev", :prev, nil, "go to the previous tab"},
       {"--go", :go, "N", "go to tab N (1 is the first)"},
       {"--rename", :rename, "NAME", ~s(name the tab; "" gives the program's title back)},
       {"--lock", :lock, nil, "keep the tab running when its window closes"},
       {"--unlock", :unlock, nil, "let the tab close with its window again"}
     ]},
    {"pane", :pane,
     [
       {"--split-right", :split_right, nil, "split the pane, the new one on the right"},
       {"--split-down", :split_down, nil, "split the pane, the new one below"},
       {"--close", :close, nil, "close the pane"},
       {"--focus", :focus, "DIRECTION", "move the window's focus left, right, up or down"},
       {"--zoom", :zoom, nil, "show the pane over its whole tab (and focus it)"},
       {"--unzoom", :unzoom, nil, "bring the tab's other panes back"},
       {"--read-only", :read_only, nil, "stop your typing from reaching the pane"},
       {"--writable", :writable, nil, "let typing reach the pane again"}
     ]},
    {"theme", :theme,
     [
       {"--set", :set, "NAME", "use a built-in theme until the config file changes"},
       {"--list", :list, nil, "list the built-in themes"}
     ]},
    {"ai", :ai,
     [
       {"--set-command", :set_command, "PROGRAM", "the program the AI key opens"},
       {"--set-position", :set_position, "POSITION", "open it on the right, down or in a tab"}
     ]},
    {"tab-bar", :tab_bar,
     [
       {"--set-position", :set_position, "SIDE", "put the tab bar at the top or the bottom"},
       {"--set-style", :set_style, "STYLE", "draw the tabs flat, powerline, rounded..."}
     ]}
  ]

  # What the words mean, as the config file spells them (Guiltty.Config).
  @ai_positions %{"right" => :right, "down" => :down, "tab" => :tab}
  @sides %{"top" => :top, "bottom" => :bottom}

  @directions %{"left" => :left, "right" => :right, "up" => :up, "down" => :down}
  @max_name 40

  @type command :: %{command: {atom(), atom(), term()}, pane: pos_integer() | nil}

  @doc """
  Checks a command's arguments (the words after `guiltty`). Returns
  `{:ok, %{command: {noun, action, argument}, pane: id or nil}}`, or
  `{:error, what to print}`. `pane` is the `--pane ID` given, if any.
  """
  @spec parse(term()) :: {:ok, command()} | {:error, binary()}
  def parse(args) when is_list(args) do
    if Enum.all?(args, &text?/1) do
      with {:ok, pane, args} <- take_pane(args, nil, []) do
        args |> Enum.flat_map(&split_equals/1) |> parse_words(pane)
      end
    else
      {:error, "arguments must be text, without control characters"}
    end
  end

  def parse(_args), do: {:error, "not a command"}

  defp text?(word), do: is_binary(word) and String.valid?(word) and not control?(word)
  defp control?(word), do: String.match?(word, ~r/[\x00-\x1f\x7f]/)

  # --pane ID can go anywhere, once.
  defp take_pane([], pane, rest), do: {:ok, pane, Enum.reverse(rest)}

  defp take_pane(["--pane=" <> id | args], pane, rest),
    do: take_pane(["--pane", id | args], pane, rest)

  defp take_pane(["--pane", id | args], nil, rest) do
    case pane_id(id) do
      {:ok, pane} -> take_pane(args, pane, rest)
      :error -> {:error, "--pane takes a pane's id, a number (see guiltty window --list)"}
    end
  end

  defp take_pane(["--pane" | _], nil, _rest),
    do: {:error, "--pane takes a pane's id (see guiltty window --list)"}

  defp take_pane(["--pane" | _], _pane, _rest), do: {:error, "--pane given twice"}
  defp take_pane([word | args], pane, rest), do: take_pane(args, pane, [word | rest])

  @doc "A pane id from text: a positive integer, or `:error`."
  def pane_id(text) do
    case Integer.parse(text) do
      {id, ""} when id > 0 -> {:ok, id}
      _ -> :error
    end
  end

  # --rename=NAME is --rename NAME. Only for flags: a tab name may have "=".
  defp split_equals("--" <> _ = word) do
    case String.split(word, "=", parts: 2) do
      [flag, value] -> [flag, value]
      [flag] -> [flag]
    end
  end

  defp split_equals(word), do: [word]

  defp parse_words([], _pane), do: {:error, "say what to do: guiltty help lists the commands"}

  defp parse_words([help], _pane) when help in ["help", "--help", "-h"],
    do: {:ok, %{command: {:help, nil, nil}, pane: nil}}

  defp parse_words([noun | words], pane) do
    case List.keyfind(@commands, noun, 0) do
      nil -> {:error, "no command #{inspect(noun)}: guiltty help lists them"}
      {_, name, actions} -> parse_action(noun, name, actions, words, pane)
    end
  end

  defp parse_action(noun, _name, actions, [], _pane),
    do: {:error, "#{noun}: say what to do: #{flags(actions)}"}

  defp parse_action(noun, name, actions, [flag | rest], pane) do
    case List.keyfind(actions, flag, 0) do
      nil ->
        {:error, "#{noun} has no #{flag}: #{flags(actions)}"}

      {_, action, nil, _} when rest == [] ->
        {:ok, %{command: {name, action, nil}, pane: pane}}

      {_, _, nil, _} ->
        {:error, "#{noun} #{flag} takes nothing more (#{Enum.join(rest, " ")}?)"}

      {_, action, arg, _} ->
        with {:ok, value} <- argument(arg, rest, "#{noun} #{flag}") do
          {:ok, %{command: {name, action, value}, pane: pane}}
        end
    end
  end

  defp flags(actions), do: actions |> Enum.map(&elem(&1, 0)) |> Enum.join(", ")

  defp argument(arg, [], what), do: {:error, "#{what} takes #{arg}"}

  defp argument("N", [n], what) do
    case Integer.parse(n) do
      {n, ""} when n > 0 -> {:ok, n}
      _ -> {:error, "#{what} takes a tab's number: 1 is the first"}
    end
  end

  defp argument("DIRECTION", [direction], what) do
    case Map.fetch(@directions, direction) do
      {:ok, direction} -> {:ok, direction}
      :error -> {:error, "#{what} takes left, right, up or down"}
    end
  end

  defp argument("NAME", [name], _what), do: {:ok, name}

  # As the config checks ai: [command: ...]: any text but blank. It runs
  # through the shell, so "claude --continue" is one PROGRAM, quoted.
  defp argument("PROGRAM", [program], what) do
    if String.trim(program) == "",
      do: {:error, "#{what} takes a program to run, like claude"},
      else: {:ok, program}
  end

  defp argument("POSITION", [position], what), do: one_word(@ai_positions, position, what)
  defp argument("SIDE", [side], what), do: one_word(@sides, side, what)

  defp argument("STYLE", [style], what),
    do: one_word(Map.new(Config.tab_styles(), &{Atom.to_string(&1), &1}), style, what)

  defp argument(arg, _many, what),
    do: {:error, "#{what} takes one #{arg} (quote it if it has spaces)"}

  defp one_word(words, word, what) do
    case Map.fetch(words, word) do
      {:ok, value} -> {:ok, value}
      :error -> {:error, "#{what} takes #{words |> Map.keys() |> Enum.sort() |> or_list()}"}
    end
  end

  defp or_list(words) do
    {last, rest} = List.pop_at(words, -1)
    if rest == [], do: last, else: Enum.join(rest, ", ") <> " or " <> last
  end

  @doc """
  The help text, as lines.
  """
  def help do
    usage = [
      "usage: guiltty                    open a window",
      "       guiltty NOUN --ACTION      control the running guiltty",
      "       guiltty release COMMAND    the release's own commands (stop, pid, remote...)",
      "       guiltty version",
      ""
    ]

    commands =
      Enum.flat_map(@commands, fn {noun, _, actions} ->
        for {flag, _, arg, what} <- actions do
          left = Enum.join(["guiltty", noun, flag | List.wrap(arg)], " ")
          "  " <> String.pad_trailing(left, 38) <> what
        end
      end)

    footer = [
      "",
      "A command acts on the pane it's typed in ($GUILTTY_PANE), or with",
      "--pane ID on another; from outside guiltty, on the window last used."
    ]

    usage ++ commands ++ footer
  end

  @doc """
  Runs a parsed command. `context` is what the request said besides the
  command: `:pane` (`GUILTTY_PANE`, or nil), `:cwd` (the client's folder,
  or nil) and `:window` (options for a new `Guiltty.Window`: its display).
  Returns `{:ok, lines to print}` or `{:error, why}`.
  """
  def run(%{command: {:help, _, _}}, _context), do: {:ok, help()}
  def run(%{command: {:window, :list, _}}, context), do: {:ok, list(context.pane)}
  def run(%{command: {:theme, action, name}}, _context), do: theme(action, name)
  def run(%{command: {:ai, action, value}}, _context), do: ai(action, value)
  def run(%{command: {:tab_bar, :set_position, side}}, _context), do: override(:tab_bar, side)
  def run(%{command: {:tab_bar, :set_style, style}}, _context), do: override(:tab_style, style)

  def run(%{command: {:window, :new, _}}, context) do
    case Lifeline.open(window: context.window, cwd: context.cwd, fresh: true) do
      {:ok, desk} -> {:ok, [to_string(Tabs.active(Desk.tabs(desk)))]}
      {:error, reason} -> {:error, "couldn't open a window: #{inspect(reason)}"}
    end
  end

  def run(%{command: {noun, action, value}, pane: given}, context) do
    with {:ok, tabs, pane} <- target(given || context.pane) do
      act(noun, action, value, tabs, pane, start_in(context.cwd))
    end
  end

  # The pane a command is about, and its window's Tabs.
  defp target(nil) do
    case Lifeline.last_focused() do
      nil -> {:error, "no window is open"}
      tabs -> {:ok, tabs, Tabs.active(tabs)}
    end
  end

  defp target(pane) do
    case desk_of(pane) do
      nil -> {:error, "there's no pane #{pane} (closed?): see guiltty window --list"}
      desk -> {:ok, Desk.tabs(desk), pane}
    end
  end

  # Every session is registered with its desk's id (Guiltty.Session.start_named/4).
  defp desk_of(pane) do
    case Registry.lookup(Guiltty.Registry, {pane, :supervisor}) do
      [{_pid, desk}] when is_integer(desk) -> desk
      _ -> nil
    end
  end

  # A new shell starts where the command was typed, as a window does
  # where `guiltty` was run: when the config says :inherit (the default).
  defp start_in(cwd) do
    if is_binary(cwd) and File.dir?(cwd) and Config.get().working_directory == :inherit,
      do: [cwd: cwd],
      else: []
  end

  defp act(:tab, :new, _, tabs, _pane, opts), do: opened(Tabs.new_tab(tabs, opts))
  defp act(:tab, :close, _, tabs, pane, _opts), do: done(Tabs.close_tab(tabs, pane))
  defp act(:tab, :next, _, tabs, _pane, _opts), do: done(Tabs.switch(tabs, :next))
  defp act(:tab, :prev, _, tabs, _pane, _opts), do: done(Tabs.switch(tabs, :prev))

  defp act(:tab, :go, n, tabs, _pane, _opts) do
    case Tabs.list(tabs) do
      {list, _active} when n <= length(list) -> done(Tabs.switch(tabs, n - 1))
      {list, _active} -> {:error, "there's no tab #{n}: this window has #{length(list)}"}
    end
  end

  defp act(:tab, :rename, name, tabs, pane, _opts),
    do: done(Tabs.rename(tabs, pane, String.slice(String.trim(name), 0, @max_name)))

  defp act(:tab, :lock, _, tabs, pane, _opts), do: done(Tabs.lock(tabs, pane, true))
  defp act(:tab, :unlock, _, tabs, pane, _opts), do: done(Tabs.lock(tabs, pane, false))

  defp act(:pane, split, _, tabs, pane, opts) when split in [:split_right, :split_down] do
    direction = if split == :split_right, do: :right, else: :down

    case Tabs.split(tabs, direction, [pane: pane] ++ opts) do
      {:error, :too_small} -> {:error, "no room to split this pane"}
      result -> opened(result)
    end
  end

  defp act(:pane, :close, _, tabs, pane, _opts), do: done(Tabs.close(tabs, pane))
  defp act(:pane, :focus, direction, tabs, _pane, _opts), do: done(Tabs.focus(tabs, direction))

  defp act(:pane, :zoom, _, tabs, pane, _opts) do
    case Tabs.zoom(tabs, pane, true) do
      {:error, :single} -> {:error, "the pane is alone in its tab: nothing to zoom"}
      result -> done(result)
    end
  end

  defp act(:pane, :unzoom, _, tabs, pane, _opts), do: done(Tabs.zoom(tabs, pane, false))
  defp act(:pane, :read_only, _, tabs, pane, _opts), do: done(Tabs.read_only(tabs, pane, true))
  defp act(:pane, :writable, _, tabs, pane, _opts), do: done(Tabs.read_only(tabs, pane, false))

  defp opened({:ok, id}), do: {:ok, [to_string(id)]}
  defp opened(error), do: done(error)

  defp done(:ok), do: {:ok, []}
  defp done({:error, :no_tab}), do: {:error, "that pane's tab is gone"}
  defp done({:error, :no_such_tab}), do: {:error, "that pane is gone"}
  defp done({:error, :no_pane}), do: {:error, "that pane is gone"}
  defp done({:error, reason}), do: {:error, inspect(reason)}

  ## theme

  defp theme(:list, _) do
    current = Config.get().theme

    {:ok,
     for name <- Theme.names() do
       if Theme.named(name) == {:ok, current}, do: name <> " (in use)", else: name
     end}
  end

  defp theme(:set, name) do
    with {:ok, name} <- theme_name(name),
         {:ok, theme} <- Theme.named(name) do
      override(:theme, theme)
    end
  end

  ## ai, tab-bar

  # One part of the ai setting; the others stay as they are.
  defp ai(action, value) do
    key = if action == :set_command, do: :command, else: :position
    override(:ai, Map.put(Config.get().ai, key, value))
  end

  # Like theme --set: for every window, until the config file changes.
  # parse/1 already checked the value as the config would.
  defp override(key, value) do
    if Process.whereis(Config),
      do: done(Config.override(key, value)),
      else: {:error, "no config process to tell"}
  end

  # The full name, or one that starts a single name ("dra" is dracula).
  @doc false
  def theme_name(name) do
    names = Theme.names()

    starting = if name == "", do: [], else: Enum.filter(names, &String.starts_with?(&1, name))

    case {name in names, starting} do
      {true, _} -> {:ok, name}
      {false, [one]} -> {:ok, one}
      {false, [_, _ | _] = many} -> {:error, "#{name} could be #{Enum.join(many, " or ")}"}
      _ -> {:error, "no theme #{inspect(name)}: guiltty theme --list shows them"}
    end
  end

  ## window --list

  # Windows numbered in the order they opened, tabs as --go counts them,
  # panes by the ids --pane takes.
  defp list(here) do
    focused = Lifeline.last_focused()

    Desk.all()
    |> Enum.sort()
    |> Enum.with_index(1)
    |> Enum.flat_map(fn {desk, n} ->
      tabs = Desk.tabs(desk)

      notes =
        [
          tabs == focused && "last used",
          Desk.windowless?(desk) && "closed, its locked tabs running"
        ]

      ["window #{n}" <> notes(notes) | describe(tabs, here)]
    end)
  end

  defp describe(tabs, here) do
    tabs
    |> Tabs.describe()
    |> Enum.with_index(1)
    |> Enum.flat_map(fn {tab, n} ->
      line =
        "  tab #{n}: #{tab.title}" <>
          notes([tab.active && "active", tab.locked && "locked", tab.zoomed && "zoomed"])

      panes =
        for pane <- tab.panes do
          "    pane #{pane.id}: #{pane.title}" <>
            notes([
              pane.focus && "focus",
              pane.read_only && "read-only",
              pane.id == here && "here"
            ])
        end

      [line | panes]
    end)
  end

  defp notes(notes) do
    case Enum.filter(notes, & &1) do
      [] -> ""
      notes -> " (" <> Enum.join(notes, ", ") <> ")"
    end
  end
end
