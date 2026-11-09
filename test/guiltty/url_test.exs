defmodule Guiltty.UrlTest do
  @moduledoc "URLs found in plain text. See Guiltty.Url."
  use ExUnit.Case, async: true
  use ExUnitProperties

  import Bitwise

  alias Guiltty.{Grid, Parser, Terminal, Url, View}

  defp run(bytes, cols \\ 80, rows \\ 5) do
    {_p, cmds} = Parser.feed(Parser.new(), bytes)
    Terminal.apply(Grid.new(cols, rows), cmds)
  end

  defp url(grid, n, col) do
    case Url.at(grid, n, col) do
      {url, _spans} -> url
      nil -> nil
    end
  end

  # What `mix phx.server` printed, as copied from the terminal.
  @phoenix "[info] Access GuilttyWebsiteWeb.Endpoint at http://localhost:4000\r\n"

  test "a server's address, from its first character to its last" do
    grid = run(@phoenix)
    start = 44
    assert grid |> Grid.line(0) |> binary_part(start * 14, 4) == <<?h::32>>

    assert Url.at(grid, 0, start) == {"http://localhost:4000", [{0, start, start + 20}]}
    assert url(grid, 0, start + 20) == "http://localhost:4000"
    assert url(grid, 0, start - 2) == nil
    assert url(grid, 0, start + 21) == nil
    assert url(grid, 1, 0) == nil
  end

  test "punctuation and brackets around it belong to the sentence" do
    assert url(run("see https://x.y/a."), 0, 4) == "https://x.y/a"
    assert url(run("(https://x.y/a)"), 0, 1) == "https://x.y/a"

    assert url(run("https://en.wikipedia.org/wiki/Rust_(language)"), 0, 0) ==
             "https://en.wikipedia.org/wiki/Rust_(language)"

    assert url(run("<https://x.y/a>, \"https://x.y/b\""), 0, 1) == "https://x.y/a"
    assert url(run("<https://x.y/a>, \"https://x.y/b\""), 0, 20) == "https://x.y/b"
    # The full stop isn't part of it, so clicking it opens nothing.
    assert url(run("see https://x.y/a."), 0, 17) == nil
  end

  test "only kinds guiltty would open" do
    assert url(run("mailto:me@x.y"), 0, 0) == "mailto:me@x.y"
    assert url(run("file:///etc/hosts"), 0, 3) == "file:///etc/hosts"
    assert url(run("ssh://x.y javascript:alert(1)"), 0, 0) == nil
    assert url(run("ssh://x.y javascript:alert(1)"), 0, 12) == nil
    assert url(run("http:// nothing"), 0, 0) == nil
  end

  test "a URL that wrapped is found from either row, even in the scrollback" do
    grid = run("go to https://example.com/a/long/path now\r\n", 20, 5)
    assert Grid.dump(grid) =~ "go to https://exampl\ne.com/a/long/path no\nw\n"

    # Both rows are still on screen.
    assert Url.at(grid, 0, 8) ==
             {"https://example.com/a/long/path", [{0, 6, 19}, {1, 0, 16}]}

    assert url(grid, 1, 3) == "https://example.com/a/long/path"
    assert url(grid, 1, 18) == nil

    # Two more lines push the first row into the scrollback.
    grid = run("go to https://example.com/a/long/path now\r\nx\r\ny\r\n", 20, 3)
    assert Grid.scrollback_size(grid) >= 2
    assert url(grid, 0, 8) == "https://example.com/a/long/path"
    assert url(grid, 1, 0) == "https://example.com/a/long/path"
  end

  test "wide characters before it don't shift its columns" do
    grid = run("日本 https://x.y")
    assert Url.at(grid, 0, 5) == {"https://x.y", [{0, 5, 15}]}
    assert url(grid, 0, 1) == nil
  end

  test "the view underlines the hovered link, and nothing else" do
    grid = run(@phoenix)
    {_url, spans} = Url.at(grid, 0, 50)
    [{0, row} | _] = View.rows(grid, 0, nil, nil, spans)

    underlined =
      for {<<_::32, a::16, _::binary-size(8)>>, col} <- Enum.with_index(cells(row)),
          (a &&& Grid.attr(:underline)) != 0,
          do: col

    assert underlined == Enum.to_list(44..64)
  end

  property "any text, any column: a URL or nil, never a crash" do
    check all(
            text <- string(:printable, max_length: 60),
            col <- integer(0..19)
          ) do
      grid = run(text, 20, 4)

      for n <- 0..3 do
        case Url.at(grid, n, col) do
          nil -> :ok
          {url, [_ | _]} -> assert url =~ ~r/^(https?:|mailto:|file:)/
        end
      end
    end
  end

  defp cells(row), do: for(<<cell::binary-size(14) <- row>>, do: cell)
end
