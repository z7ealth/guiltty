defmodule Guiltty.TextNif do
  @moduledoc false
  # Thin bindings for c_src/text_nif.c. Only Guiltty.Grid calls these.

  @on_load :load_nif

  def load_nif do
    :guiltty
    |> :code.priv_dir()
    |> Path.join("text_nif")
    |> String.to_charlist()
    |> :erlang.load_nif(0)
  end

  @doc """
  Splits printed text (valid UTF-8) into cells C made and text Elixir must
  segment, in order: a list of `{cells, cols}` (cells in `Guiltty.Grid`'s
  layout, in the pen `attrs`, `fg`, `bg`) and binaries. Segmenting each
  binary alone gives the clusters segmenting the whole text would.
  """
  def segments(_text, _attrs, _fg, _bg), do: :erlang.nif_error(:not_loaded)

  @doc """
  How many bytes at the start of `bytes` may be text: printable ASCII and
  any byte >= 0x80. Stops at a C0 control or DEL.
  """
  def text_run(_bytes), do: :erlang.nif_error(:not_loaded)

  @doc "Whether no byte of `bytes` is >= 0x80."
  def ascii?(_bytes), do: :erlang.nif_error(:not_loaded)

  @doc "One cell per byte of ASCII `text`, in the pen."
  def ascii_cells(_text, _attrs, _fg, _bg), do: :erlang.nif_error(:not_loaded)
end
