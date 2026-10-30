defmodule Guiltty.CheatsheetTest do
  use ExUnit.Case, async: true

  alias Guiltty.{Cheatsheet, Config, Grid}

  defp text(lines, cols) do
    grid = Grid.new(cols, 1)
    Enum.map_join(lines, "\n", &(grid |> Grid.line_text(&1) |> String.trim_trailing()))
  end

  test "shows the keys from the config, as people write them" do
    config = Config.defaults()
    sheet = config |> Cheatsheet.render(90) |> text(90)
    assert sheet =~ ~r/New tab +Ctrl\+Shift\+T/
    assert sheet =~ "Ctrl+PgDn / Ctrl+Tab"
    assert sheet =~ "This cheatsheet"

    rebound = put_in(config.keys.new_tab, ["alt+n"])
    assert rebound |> Cheatsheet.render(90) |> text(90) =~ ~r/New tab +Alt\+N/
  end

  test "every row is exactly the screen's width" do
    for cols <- [40, 80, 90, 200] do
      lines = Cheatsheet.render(Config.defaults(), cols)
      assert Enum.all?(lines, &(byte_size(&1) == cols * Grid.cell_size()))
    end
  end

  test "cards sit in a centered grid: balanced rows, tops and bottoms lined up" do
    sheet = Config.defaults() |> Cheatsheet.render(230) |> text(230) |> String.split("\n")

    # Room for 5 per row, but 6 cards: two rows of 3.
    tops = Enum.filter(sheet, &String.contains?(&1, "╭─"))
    bottoms = Enum.filter(sheet, &String.contains?(&1, "╰─"))
    assert Enum.map(tops, &length(String.split(&1, "╭─"))) == [4, 4]
    assert Enum.map(bottoms, &length(String.split(&1, "╰─"))) == [4, 4]

    # Centered: as much room on the left as on the right (give or take one).
    [first | _] = tops
    left = String.length(first) - String.length(String.trim_leading(first))
    right = 230 - String.length(first)
    assert abs(left - right) <= 1
  end

  test "a narrow screen gets one column; keys that don't fit get their own line" do
    sheet = Config.defaults() |> Cheatsheet.render(40) |> text(40)
    refute sheet =~ ~r/╮ +╭/
    assert sheet =~ ~r/Previous tab +│\n +│ +Ctrl\+PgUp \/ Ctrl\+Shift\+Tab │/
    # The help text only shows where it fits next to the title.
    refute sheet =~ "arrows scrol\n"
  end
end
