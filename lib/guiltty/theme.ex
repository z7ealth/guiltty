defmodule Guiltty.Theme do
  @moduledoc """
  The colors: what RGB each of the 256 palette entries means, plus the
  default foreground, background and cursor. The renderer gets the theme
  once, in the setup message, and applies it to every cell.

  Palette layout (the same as xterm's):

    * 0-15: the 16 "ANSI" colors (8 normal, 8 bright), from the theme
    * 16-231: a 6x6x6 color cube
    * 232-255: a ramp of 24 grays

  Live themes from a config file come in MVP 4.
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
