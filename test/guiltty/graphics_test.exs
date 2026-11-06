defmodule Guiltty.GraphicsTest do
  @moduledoc """
  v0.18: images (Kitty graphics) as the grid keeps them, with
  no renderer: what shows where, what's answered, what's refused.
  """
  use ExUnit.Case, async: true

  alias Guiltty.{Grid, Parser, Terminal}

  @fixtures Path.expand("../fixtures/images", __DIR__)

  defp run(bytes, grid \\ Grid.new(20, 10, cell_pixels: {10, 20})) do
    {_p, cmds} = Parser.feed(Parser.new(), bytes)
    Terminal.apply(grid, cmds)
  end

  defp view(grid, scroll \\ 0), do: Grid.graphics_view(grid, scroll)
  defp placements(grid, scroll \\ 0), do: grid |> view(scroll) |> elem(0)

  defp answers(grid),
    do: grid |> Grid.take_responses() |> elem(0) |> Enum.map(&IO.iodata_to_binary/1)

  # Kitty graphics: ESC _ G control ; base64 payload ESC \
  defp kitty(control, data \\ ""), do: "\e_G#{control};#{Base.encode64(data)}\e\\"
  defp rgb(w, h), do: :binary.copy(<<255, 0, 0>>, w * h)
  defp rgba(w, h), do: :binary.copy(<<0, 255, 0, 255>>, w * h)

  describe "yazi, recorded (test/fixtures/images/record_yazi.py)" do
    test "Kitty: shows one picture, erases it (d=A), shows the next" do
      grid =
        run(
          File.read!(Path.join(@fixtures, "yazi_kitty.bytes")),
          Grid.new(100, 30, cell_pixels: {9, 18})
        )

      # Its preview pane starts at row 2, column 64 (1-based); the
      # second image is 32 x 48, under the text (z = -1).
      assert [%{row: 1, col: 63, z: -1, source: {0, 0, 32, 48}, uid: uid}] = placements(grid)
      assert %{^uid => %{format: :rgb, width: 32, height: 48}} = elem(view(grid), 1)
      # The first image was anonymous: once erased, it's gone too.
      assert map_size(grid.graphics.images) == 1
      # Its question about Kitty graphics was answered, in order with the rest.
      assert "\e_Gi=31;OK\e\\" in answers(grid)
    end
  end

  describe "kitten icat, recorded with script(1) inside guiltty" do
    test "a picture in chunks that each repeat a=T: one image, shown" do
      # A 300 x 200 JPEG: icat decodes it, then sends RGB in two chunks,
      # the second with a=T,q=2 again (yazi sends only m=).
      grid =
        run(
          File.read!(Path.join(@fixtures, "icat.bytes")),
          Grid.new(80, 24, cell_pixels: {9, 18})
        )

      assert [%{source: {0, 0, 300, 200}, uid: uid}] = placements(grid)
      assert %{^uid => %{format: :rgb, width: 300, height: 200}} = elem(view(grid), 1)
    end
  end

  describe "Kitty: sending and showing" do
    test "a=T shows the image at the cursor, at its own size in cells" do
      grid = run("\e[3;5H" <> kitty("a=T,f=24,s=25,v=30", rgb(25, 30)))
      # 25 x 30 pixels in 10 x 20 cells: 3 columns, 2 rows.
      assert [%{row: 2, col: 4, cells: {0, 0}, z: 0}] = placements(grid)
      assert [%{span: {3, 2}}] = grid.graphics.placements
      # The cursor moves past it, on its last row, as text would leave it.
      assert Grid.cursor(grid) == {3, 7}
    end

    test "C=1 leaves the cursor where it was" do
      grid = run("\e[3;5H" <> kitty("a=T,C=1,f=24,s=25,v=30", rgb(25, 30)))
      assert Grid.cursor(grid) == {2, 4}
    end

    test "sent in chunks (m=1), each its own piece of base64" do
      data = Base.encode64(rgba(4, 4))
      <<a::binary-size(20), b::binary-size(20), c::binary>> = data

      grid =
        run("\e_Ga=T,f=32,s=4,v=4,i=9,m=1;#{a}\e\\\e_Gm=1;#{b}\e\\\e_Gm=0;#{c}\e\\")

      assert [%{source: {0, 0, 4, 4}}] = placements(grid)
      assert answers(grid) == ["\e_Gi=9;OK\e\\"]
    end

    test "a chunk that repeats the first one's action and id goes on the same image" do
      <<a::binary-size(16), b::binary>> = Base.encode64(rgb(4, 4))
      grid = run("\e_Ga=T,f=24,s=4,v=4,i=3,m=1;#{a}\e\\\e_Ga=T,i=3;#{b}\e\\")
      assert [%{source: {0, 0, 4, 4}}] = placements(grid)
      assert answers(grid) == ["\e_Gi=3;OK\e\\"]

      # Another image's id, or another action, starts anew: the first is
      # dropped, unfinished.
      grid = run("\e_Ga=T,f=24,s=4,v=4,i=3,m=1;#{a}\e\\" <> kitty("a=d,d=a"))
      assert placements(grid) == [] and grid.graphics.upload == nil
    end

    test "a=t keeps it, a=p shows it, again and again" do
      grid = run(kitty("a=t,f=24,s=2,v=2,i=5", rgb(2, 2)) <> "\e[2;2H" <> kitty("a=p,i=5,p=1"))
      grid = run("\e[5;5H" <> kitty("a=p,i=5,p=2,c=4,r=2"), grid)
      assert [%{row: 1, col: 1}, %{row: 4, col: 4, cells: {4, 2}}] = placements(grid)
      assert answers(grid) == ["\e_Gi=5;OK\e\\", "\e_Gi=5,p=1;OK\e\\", "\e_Gi=5,p=2;OK\e\\"]

      # The same placement id again moves it instead of adding one.
      grid = run("\e[8;1H" <> kitty("a=p,i=5,p=2,q=1"), grid)
      assert [%{row: 1}, %{row: 7, col: 0}] = placements(grid)
    end

    test "one of c and r keeps the picture's shape" do
      grid = run(kitty("a=T,f=24,s=40,v=20,c=4", rgb(40, 20)))
      # 4 columns of 10 pixels is the image's 40: 20 pixels high, one row.
      assert [%{span: {4, 1}}] = grid.graphics.placements
    end

    test "I= asks guiltty for an id, and gets both back" do
      grid = run(kitty("a=t,f=24,s=1,v=1,I=77", rgb(1, 1)))
      assert ["\e_Gi=" <> rest] = answers(grid)
      assert rest =~ ~r/\A\d+,I=77;OK\e\\\z/
    end

    test "q=1 hides the OK, q=2 errors too; no id, no answer" do
      assert answers(run(kitty("a=t,f=24,s=1,v=1,i=1,q=1", rgb(1, 1)))) == []
      assert answers(run(kitty("a=p,i=2,q=2"))) == []
      assert answers(run(kitty("a=p,i=2"))) == ["\e_Gi=2;ENOENT:no such image\e\\"]
      assert answers(run(kitty("a=T,f=24,s=1,v=1", rgb(1, 1)))) == []
    end

    test "a=q checks without keeping anything" do
      grid = run(kitty("a=q,i=31,s=1,v=1,f=24", <<0, 0, 0>>))
      assert answers(grid) == ["\e_Gi=31;OK\e\\"]
      assert grid.graphics.images == %{}
    end

    test "PNG: its size comes from its header" do
      png = File.read!(Path.join(@fixtures, "red.png"))
      grid = run(kitty("a=T,f=100", png))
      assert [%{source: {0, 0, 30, 40}, uid: uid}] = placements(grid)
      assert %{^uid => %{format: :png, data: ^png}} = elem(view(grid), 1)
    end

    test "zlib-compressed data (o=z) is inflated" do
      grid = run(kitty("a=T,f=24,s=8,v=8,o=z", :zlib.compress(rgb(8, 8))))
      assert [%{uid: uid}] = placements(grid)
      assert byte_size(elem(view(grid), 1)[uid].data) == 8 * 8 * 3
    end
  end

  describe "Kitty: refused" do
    test "anything but direct data: t=f would read your files, by name, for a remote program" do
      grid = run(kitty("a=T,t=f,i=1", "/etc/passwd"))
      assert answers(grid) == ["\e_Gi=1;EINVAL:only direct transmission (t=d) is supported\e\\"]
      assert grid.graphics.images == %{}
    end

    test "a zlib bomb stops at what the image can hold" do
      bomb = :zlib.compress(:binary.copy(<<0>>, 10_000_000))
      grid = run(kitty("a=T,f=24,s=10,v=10,o=z,i=1", bomb))
      assert answers(grid) == ["\e_Gi=1;EFBIG:image too big\e\\"]
    end

    test "sizes: too big, too small, or data that doesn't match" do
      assert ["\e_Gi=1;EINVAL:width and height" <> _] =
               answers(run(kitty("a=T,f=24,s=5000,v=1,i=1", rgb(1, 1))))

      assert answers(run(kitty("a=T,f=24,s=2,v=2,i=1", rgb(1, 1)))) ==
               ["\e_Gi=1;ENODATA:not 2x2 pixels of data\e\\"]

      assert answers(run(kitty("a=T,f=100,i=1", "GIF89a"))) == ["\e_Gi=1;EINVAL:not a PNG\e\\"]

      assert answers(run("\e_Ga=T,f=24,s=1,v=1,i=1;!!!!\e\\")) == [
               "\e_Gi=1;EINVAL:bad base64\e\\"
             ]
    end

    test "past the memory limit, the oldest images go first" do
      big = rgba(1024, 1024)

      grid =
        Enum.reduce(1..20, Grid.new(20, 10), fn i, grid ->
          run(kitty("a=t,q=2,f=32,s=1024,v=1024,i=#{i}", big), grid)
        end)

      assert grid.graphics.bytes <= 64 * 1024 * 1024
      ids = Map.keys(grid.graphics.images)
      assert 20 in ids and 1 not in ids
    end
  end

  describe "Kitty: deleting (a=d)" do
    setup do
      grid =
        run(
          kitty("a=t,q=2,f=24,s=1,v=1,i=1", rgb(1, 1)) <>
            kitty("a=t,q=2,f=24,s=1,v=1,i=2", rgb(1, 1)) <>
            "\e[1;1H" <> kitty("a=p,q=2,i=1,C=1") <> "\e[3;3H" <> kitty("a=p,q=2,i=2,z=5,C=1")
        )

      %{grid: grid}
    end

    test "d=a: every one that shows; the images stay", %{grid: grid} do
      grid = run(kitty("a=d,d=a"), grid)
      assert placements(grid) == []
      assert map_size(grid.graphics.images) == 2
    end

    test "d=I: its placements, and the image itself", %{grid: grid} do
      # Named images (i=) stay unless asked: only lower case keeps them.
      grid = run(kitty("a=d,d=I,i=1"), grid)
      assert [%{z: 5}] = placements(grid)
      refute Map.has_key?(grid.graphics.images, 1)
    end

    test "d=c: under the cursor; d=z: by z-index; d=i: by image", %{grid: grid} do
      assert [%{z: 5}] = grid |> then(&run("\e[1;1H" <> kitty("a=d,d=c"), &1)) |> placements()
      assert [%{z: 0}] = grid |> then(&run(kitty("a=d,d=z,z=5"), &1)) |> placements()
      assert [%{z: 5}] = grid |> then(&run(kitty("a=d,d=i,i=1"), &1)) |> placements()
    end
  end

  describe "placements move with the text" do
    test "the screen scrolls: the image goes up with its line" do
      grid = run("\e[5;1H" <> kitty("a=T,C=1,f=24,s=1,v=1", rgb(1, 1)) <> "\e[10;1H\n\n")
      assert [%{row: 2}] = placements(grid)
    end

    test "scrolled back, it shows lower; scrolled off the scrollback, it's gone" do
      grid = run("\e[2;1H" <> kitty("a=T,C=1,f=24,s=1,v=60", rgb(1, 60)) <> "\e[10;1H\n\n\n")
      # Three rows tall, two of them scrolled off: the last still shows.
      assert [%{row: -2}] = placements(grid)
      assert [%{row: 1}] = placements(grid, 3)

      small = Grid.new(20, 10, scrollback: 2, cell_pixels: {10, 20})

      grid =
        run("\e[1;1H" <> kitty("a=T,C=1,f=24,s=1,v=1", rgb(1, 1)) <> "\e[10;1H\n\n\n\n", small)

      assert grid.graphics.placements == []
    end

    test "a clear screen (ED 2), a full reset or leaving the alternate screen removes them" do
      img = kitty("a=T,C=1,f=24,s=1,v=1,i=1,q=2", rgb(1, 1))
      assert placements(run(img <> "\e[2J")) == []
      assert run(img <> "\ec").graphics.images == %{}
      grid = run("\e[?1049h" <> img)
      assert [_] = placements(grid)
      grid = run("\e[?1049l", grid)
      assert grid.graphics.placements == []
    end

    test "the alternate screen's images don't show on the main one, and back" do
      grid = run(kitty("a=T,C=1,f=24,s=1,v=1", rgb(1, 1)) <> "\e[?1049h")
      assert placements(grid) == []
      assert [_] = placements(run("\e[?1049l", grid))
    end

    test "text over an image leaves it: it's under or over the cells, not in them" do
      grid = run(kitty("a=T,C=1,f=24,s=30,v=40", rgb(30, 40)) <> "hello")
      assert [_] = placements(grid)
    end
  end
end
