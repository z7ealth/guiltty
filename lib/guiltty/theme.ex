defmodule Guiltty.Theme do
  @moduledoc """
  The colors: what RGB each of the 256 palette entries means, plus the
  default foreground, background and cursor. The renderer gets the theme
  once, in the setup message, and applies it to every cell.

  Palette layout (the same as xterm's):

    * 0-15: the 16 "ANSI" colors (8 normal, 8 bright), from the theme
    * 16-231: a 6x6x6 color cube
    * 232-255: a ramp of 24 grays

  Besides the default, a few well-known themes come built in by name (see
  `named/1`); the config can start from one and change single colors.
  """

  defstruct [:fg, :bg, :cursor, :ansi]

  @type rgb :: {0..255, 0..255, 0..255}
  @type t :: %__MODULE__{fg: rgb(), bg: rgb(), cursor: rgb(), ansi: [rgb()]}

  @doc "Tomorrow Night, a calm dark theme."
  @spec default() :: t()
  def default do
    %__MODULE__{
      fg: {0xC5, 0xC8, 0xC6},
      bg: {0x1D, 0x1F, 0x21},
      cursor: {0xC5, 0xC8, 0xC6},
      ansi: [
        # black, red, green, yellow, blue, magenta, cyan, white
        {0x1D, 0x1F, 0x21},
        {0xCC, 0x66, 0x66},
        {0xB5, 0xBD, 0x68},
        {0xF0, 0xC6, 0x74},
        {0x81, 0xA2, 0xBE},
        {0xB2, 0x94, 0xBB},
        {0x8A, 0xBE, 0xB7},
        {0xC5, 0xC8, 0xC6},
        # the bright versions
        {0x96, 0x98, 0x96},
        {0xD5, 0x4E, 0x53},
        {0xB9, 0xCA, 0x4A},
        {0xE7, 0xC5, 0x47},
        {0x7A, 0xA6, 0xDA},
        {0xC3, 0x97, 0xD8},
        {0x70, 0xC0, 0xB1},
        {0xEA, 0xEA, 0xEA}
      ]
    }
  end

  # The published terminal palettes of each theme: fg, bg, cursor, then the
  # 16 ANSI colors (8 normal, 8 bright).
  @named %{
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
          #585b70 #f38ba8 #a6e3a1 #f9e2af #89b4fa #f5c2e7 #94e2d5 #a6adc8)}
  }

  @doc "The names `named/1` knows."
  def names, do: ["tomorrow-night" | Map.keys(@named)] |> Enum.sort()

  @doc "A built-in theme by name, or `:error`."
  @spec named(binary()) :: {:ok, t()} | :error
  def named("tomorrow-night"), do: {:ok, default()}

  def named(name) do
    with {:ok, {fg, bg, cursor, ansi}} <- Map.fetch(@named, name) do
      {:ok,
       %__MODULE__{fg: rgb(fg), bg: rgb(bg), cursor: rgb(cursor), ansi: Enum.map(ansi, &rgb/1)}}
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
