defmodule Guiltty.Theme do
  @moduledoc """
  The colors: what RGB each of the 256 palette entries means, plus the
  default foreground, background and cursor. The renderer gets the theme
  once, in the setup message, and applies it to every cell.

  Palette layout (the same as xterm's):

    * 0-15: the 16 "ANSI" colors (8 normal, 8 bright), from the theme
    * 16-231: a 6x6x6 color cube
    * 232-255: a ramp of 24 grays

  The default is guiltty's own theme (the icon's lavender on near-black).
  It and several well-known themes come built in by name (see `named/1`);
  the config can start from one and change single colors.

  The tab bar's colors (`tab_bar`, `tab_text`, `tab_active`,
  `tab_active_text`, `tab_accent`) are nil unless the config sets them:
  then the renderer derives each from the colors above, as fits the tab
  style. So are the split panes' borders (`pane_border`, and
  `pane_border_active` along the focused pane): unset, they're the
  palette's bright black and blue.
  """

  @tab_colors [:tab_bar, :tab_text, :tab_active, :tab_active_text, :tab_accent]
  @pane_colors [:pane_border, :pane_border_active]

  defstruct [:fg, :bg, :cursor, :ansi] ++ @tab_colors ++ @pane_colors

  @type rgb :: {0..255, 0..255, 0..255}
  @type t :: %__MODULE__{
          fg: rgb(),
          bg: rgb(),
          cursor: rgb(),
          ansi: [rgb()],
          tab_bar: rgb() | nil,
          tab_text: rgb() | nil,
          tab_active: rgb() | nil,
          tab_active_text: rgb() | nil,
          tab_accent: rgb() | nil,
          pane_border: rgb() | nil,
          pane_border_active: rgb() | nil
        }

  @doc "The tab bar's color names, in the order the renderer numbers them."
  def tab_colors, do: @tab_colors

  @doc "The split panes' border colors."
  def pane_colors, do: @pane_colors

  @doc "guiltty's own theme, what guiltty uses without a config."
  @spec default() :: t()
  def default do
    {:ok, theme} = named("guiltty")
    theme
  end

  # The published terminal palettes of each theme: fg, bg, cursor, then the
  # 16 ANSI colors (8 normal, 8 bright).
  @named %{
    "tomorrow-night" =>
      {"#c5c8c6", "#1d1f21", "#c5c8c6",
       ~w(#1d1f21 #cc6666 #b5bd68 #f0c674 #81a2be #b294bb #8abeb7 #c5c8c6
          #969896 #d54e53 #b9ca4a #e7c547 #7aa6da #c397d8 #70c0b1 #eaeaea)},
    "dracula" =>
      {"#f8f8f2", "#282a36", "#f8f8f2",
       ~w(#21222c #ff5555 #50fa7b #f1fa8c #bd93f9 #ff79c6 #8be9fd #f8f8f2
          #6272a4 #ff6e6e #69ff94 #ffffa5 #d6acff #ff92df #a4ffff #ffffff)},
    "gruvbox-dark" =>
      {"#ebdbb2", "#282828", "#ebdbb2",
       ~w(#282828 #cc241d #98971a #d79921 #458588 #b16286 #689d6a #a89984
          #928374 #fb4934 #b8bb26 #fabd2f #83a598 #d3869b #8ec07c #ebdbb2)},
    "solarized-dark" =>
      {"#839496", "#002b36", "#93a1a1",
       ~w(#073642 #dc322f #859900 #b58900 #268bd2 #d33682 #2aa198 #eee8d5
          #002b36 #cb4b16 #586e75 #657b83 #839496 #6c71c4 #93a1a1 #fdf6e3)},
    "catppuccin-mocha" =>
      {"#cdd6f4", "#1e1e2e", "#f5e0dc",
       ~w(#45475a #f38ba8 #a6e3a1 #f9e2af #89b4fa #f5c2e7 #94e2d5 #bac2de
          #585b70 #f38ba8 #a6e3a1 #f9e2af #89b4fa #f5c2e7 #94e2d5 #a6adc8)},
    "catppuccin-latte" =>
      {"#4c4f69", "#eff1f5", "#dc8a78",
       ~w(#5c5f77 #d20f39 #40a02b #df8e1d #1e66f5 #ea76cb #179299 #acb0be
          #6c6f85 #d20f39 #40a02b #df8e1d #1e66f5 #ea76cb #179299 #bcc0cc)},
    "nord" =>
      {"#d8dee9", "#2e3440", "#d8dee9",
       ~w(#3b4252 #bf616a #a3be8c #ebcb8b #81a1c1 #b48ead #88c0d0 #e5e9f0
          #4c566a #bf616a #a3be8c #ebcb8b #81a1c1 #b48ead #8fbcbb #eceff4)},
    "one-dark" =>
      {"#abb2bf", "#282c34", "#528bff",
       ~w(#1e2127 #e06c75 #98c379 #d19a66 #61afef #c678dd #56b6c2 #abb2bf
          #5c6370 #e06c75 #98c379 #d19a66 #61afef #c678dd #56b6c2 #ffffff)},
    "tokyo-night" =>
      {"#c0caf5", "#1a1b26", "#c0caf5",
       ~w(#15161e #f7768e #9ece6a #e0af68 #7aa2f7 #bb9af7 #7dcfff #a9b1d6
          #414868 #f7768e #9ece6a #e0af68 #7aa2f7 #bb9af7 #7dcfff #c0caf5)},
    # guiltty's own: the icon's near-black (#0d1117) and lavender (#9184d9),
    # with its light gray (#e9e9ed) as bright white. Magenta is the lavender,
    # and the other hues are softened to sit beside it.
    "guiltty" =>
      {"#d9d9e3", "#0d1117", "#9184d9",
       ~w(#161b22 #e0707e #8fcf9a #e6c27a #7aa2e8 #9184d9 #79c7d1 #c9cad6
          #5b5f73 #f08a96 #a9e0b2 #f0d595 #9bbcf2 #b0a6ec #99dbe3 #e9e9ed)}
  }

  # Tab bar and pane border colors a named theme sets itself, where the
  # renderer's derived ones (the palette's blue) wouldn't fit it.
  @named_extras %{
    "guiltty" => [
      tab_accent: "#9184d9",
      pane_border: "#30363d",
      pane_border_active: "#9184d9"
    ]
  }

  @doc "The names `named/1` knows."
  def names, do: @named |> Map.keys() |> Enum.sort()

  @doc "A built-in theme by name, or `:error`."
  @spec named(binary()) :: {:ok, t()} | :error
  def named(name) do
    with {:ok, {fg, bg, cursor, ansi}} <- Map.fetch(@named, name) do
      extras = for {key, hex} <- Map.get(@named_extras, name, []), do: {key, rgb(hex)}

      {:ok,
       struct(
         %__MODULE__{fg: rgb(fg), bg: rgb(bg), cursor: rgb(cursor), ansi: Enum.map(ansi, &rgb/1)},
         extras
       )}
    end
  end

  defp rgb("#" <> hex) do
    <<r, g, b>> = Base.decode16!(hex, case: :lower)
    {r, g, b}
  end

  @doc "All 256 palette colors."
  @spec palette(t()) :: [rgb()]
  def palette(%__MODULE__{ansi: ansi}), do: ansi ++ cube() ++ grays()

  # xterm's cube levels: 0, then 95 + 40k.
  defp cube do
    levels = [0, 95, 135, 175, 215, 255]
    for r <- levels, g <- levels, b <- levels, do: {r, g, b}
  end

  defp grays, do: for(i <- 0..23, do: {8 + 10 * i, 8 + 10 * i, 8 + 10 * i})
end
