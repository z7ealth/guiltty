defmodule Guiltty.ConformanceCases do
  @moduledoc """
  What guiltty should do with each control sequence, according to XTerm's
  control sequences document (ctlseqs) and the `xterm-256color` terminfo
  entry. Each case is `{id, bytes, check}`: the bytes go through the real
  parser and grid (20 columns, 5 rows), and `check` looks at the result.

  Some checks read fields the grid doesn't have yet (`Map.get(grid, :tabs)`).
  Those name where the feature is expected to show up; the slice that adds
  it can rename them.
  """

  alias Guiltty.Grid

  defp line(grid, n \\ 0), do: grid |> Grid.dump() |> String.split("\n") |> Enum.at(n, "")
  defp cursor(grid), do: Grid.cursor(grid)
  defp replied(grid), do: grid.responses |> Enum.reverse() |> IO.iodata_to_binary()
  defp input(grid, key), do: Map.get(grid.input, key)

  def all do
    [
      # Moving the cursor
      {:cup, "\e[2;3H", &(cursor(&1) == {1, 2})},
      {:home, "\e[2;3H\e[H", &(cursor(&1) == {0, 0})},
      {:cub, "abc\e[2D", &(cursor(&1) == {0, 1})},
      {:cub1, "abc\b", &(cursor(&1) == {0, 2})},
      {:cuf, "\e[3C", &(cursor(&1) == {0, 3})},
      {:cuu, "\e[3;1H\e[2A", &(cursor(&1) == {0, 0})},
      {:cud, "\e[2B", &(cursor(&1) == {2, 0})},
      {:cr, "abc\r", &(cursor(&1) == {0, 0})},
      {:hpa, "\e[5G", &(cursor(&1) == {0, 4})},
      {:vpa, "\e[3d", &(cursor(&1) == {2, 0})},
      {:nel, "abc\eE", &(cursor(&1) == {1, 0})},
      {:ind, "abc\n", &(cursor(&1) == {1, 3})},
      {:ri, "\e[2;1H\eM", &(cursor(&1) == {0, 0})},
      {:sc_rc, "\e[2;3H\e7\e[H\e8", &(cursor(&1) == {1, 2})},
      {:csr, "\e[2;3r\e[3;1H\n", &(cursor(&1) == {2, 0})},

      # Tabs
      {:ht, "\tx", &(line(&1) == "        x")},
      {:hts, "\e[5G\eH\r\tx", &(line(&1) == "    x")},
      {:tbc, "\e[3g\tx", &(cursor(&1) == {0, 19})},
      {:cbt, "abc\e[Zy", &(line(&1) == "ybc")},
      {:cht, "\e[2Ix", &(cursor(&1) == {0, 17})},

      # Editing
      {:clear, "abc\e[H\e[2J", &(line(&1) == "")},
      {:ed, "abc\e[2;1Hdef\e[1;2H\e[J", &(line(&1) == "a" and line(&1, 1) == "")},
      {:el, "abcdef\e[3G\e[K", &(line(&1) == "ab")},
      {:el1, "abcdef\e[3G\e[1K", &(line(&1) == "   def")},
      {:ech, "abcdef\e[2G\e[2X", &(line(&1) == "a  def")},
      {:ich, "abcdef\e[2G\e[2@", &(line(&1) == "a  bcdef")},
      {:dch, "abcdef\e[2G\e[2P", &(line(&1) == "adef")},
      {:il, "abc\e[1G\e[L", &(line(&1) == "" and line(&1, 1) == "abc")},
      {:dl, "abc\r\ndef\e[1;1H\e[M", &(line(&1) == "def")},
      {:indn, "abc\r\ndef\e[S", &(line(&1) == "def")},
      {:rin, "abc\e[T", &(line(&1) == "" and line(&1, 1) == "abc")},
      {:rep, "x\e[2b", &(line(&1) == "xxx")},
      {:insert_mode, "abc\e[1G\e[4hx\e[4l", &(line(&1) == "xabc")},
      {:decsca_decsed, "\e[1\"qab\e[0\"qcd\e[?2J", &(line(&1) == "ab")},
      {:decsel, "\e[1\"qab\e[0\"qcd\e[?2K", &(line(&1) == "ab")},
      {:sl, "abcdef\e[1 @", &(line(&1) == "bcdef")},
      {:sr, "abcdef\e[1 A", &(line(&1) == " abcdef")},
      {:decic, "abc\e[1G\e[1'}", &(line(&1) == " abc")},
      {:decdc, "abc\e[1G\e[1'~", &(line(&1) == "bc")},
      {:decbi, "abc\e[1G\e6", &(line(&1) == " abc")},
      {:decfi, "abc\e[20G\e9", &String.starts_with?(line(&1), "bc")},
      {:decfra, "\e[88;1;1;1;3$x", &(line(&1) == "XXX")},
      {:decera, "abc\e[1;1;1;2$z", &(line(&1) == "  c")},
      {:deccra, "abc\e[1;1;1;3;1;2;1;1$v", &(line(&1, 1) == "abc")},
      {:deccara, "abc\e[1;1;1;3;1$r", &(Grid.cell(&1, 0, 2) |> elem(1) == Grid.attr(:bold))},
      {:decrara, "abc\e[1;1;1;3;1$t\e[1;1;1;2;1$t", &(Grid.cell(&1, 0, 0) |> elem(1) == 0)},
      {:decslrm, "\e[?69h\e[2;5s\e[1;5Hab", &(cursor(&1) == {1, 2})},
      {:mgc, "\e[?69h\e[2;5s\e[?69l\e[1;5Hab", &(cursor(&1) == {0, 6})},

      # Attributes and color
      {:bold, "\e[1m", &(&1.attrs != 0)},
      {:dim, "\e[2m", &(&1.attrs != 0)},
      {:sitm, "\e[3m", &(&1.attrs != 0)},
      {:smul, "\e[4m", &(&1.attrs != 0)},
      {:blink, "\e[5m", &(&1.attrs != 0)},
      {:rev, "\e[7m", &(&1.attrs != 0)},
      {:invis, "\e[8m", &(&1.attrs != 0)},
      {:smxx, "\e[9m", &(&1.attrs != 0)},
      {:sgr0, "\e[1;4;7m\e[m", &(&1.attrs == 0)},
      {:ritm, "\e[3m\e[23m", &(&1.attrs == 0)},
      {:rmul, "\e[4m\e[24m", &(&1.attrs == 0)},
      {:rmso, "\e[7m\e[27m", &(&1.attrs == 0)},
      {:rmxx, "\e[9m\e[29m", &(&1.attrs == 0)},
      {:setaf, "\e[38;5;196m", &(&1.fg != Grid.new(1, 1).fg)},
      {:setab, "\e[48;5;196m", &(&1.bg != Grid.new(1, 1).bg)},
      {:op, "\e[31;42m\e[39;49m", &(&1.fg == Grid.new(1, 1).fg and &1.bg == Grid.new(1, 1).bg)},
      {:overline, "\e[53m", &(&1.attrs != 0)},
      {:xtpushsgr_popsgr, "\e[1m\e[\#{\e[m\e[\#}", &(&1.attrs != 0)},

      # Line drawing
      {:smacs, "\e(0q", &(line(&1) == "─")},
      {:rmacs, "\e(0\e(Bq", &(line(&1) == "q")},
      {:latin1_g2, "\e.A\eNA", &(line(&1) == "Á")},
      {:g2_ss2, "\e*0\eNq", &(line(&1) == "─")},
      {:g3_ss3, "\e+0\eOq", &(line(&1) == "─")},

      # Modes
      {:civis, "\e[?25l", &(not &1.cursor_visible)},
      {:cnorm, "\e[?25l\e[?12l\e[?25h", & &1.cursor_visible},
      {:smam_rmam, "\e[?7l" <> String.duplicate("x", 25), &(cursor(&1) == {0, 19})},
      {:am_xenl, String.duplicate("x", 20), &(cursor(&1) == {0, 19} and line(&1, 1) == "")},
      {:smcup_rmcup, "\e[?1049habc\e[?1049l", &(line(&1) == "" and not &1.alt?)},
      {:title_stack, "\e]2;one\a\e[22;0t\e]2;two\a\e[23;0t", &(&1.title == "one")},
      {:smkx, "\e[?1h\e=", &(input(&1, :cursor_keys) == :application)},
      {:rmkx, "\e[?1h\e=\e[?1l\e>", &(input(&1, :cursor_keys) == :normal)},
      {:be_bd, "\e[?2004h", &(input(&1, :bracketed_paste) == true)},
      {:xm_mouse, "\e[?1006;1000h", &(input(&1, :mouse) == 1000 and input(&1, :mouse_sgr))},
      {:cursor_style, "\e[5 q", &(&1.cursor_style == {:bar, true})},
      {:cursor_style_reset, "\e[5 q\e[ q", &(&1.cursor_style == nil)},
      {:e3, "\e[3J", &(Grid.scrollback_size(&1) == 0)},
      {:is2_rs2, "\e[1m\e[!p\e[?3;4l\e[4l\e>", &(&1.attrs == 0)},
      {:rs1, "abc\ec\e]104\e\\", &(line(&1) == "")},
      {:flash_decscnm, "\e[?5h", &(Map.get(&1, :reverse_video) == true)},
      {:lnm, "abc\e[20h\n", &(cursor(&1) == {1, 0})},
      {:fe_fd_focus, "\e[?1004h", &(input(&1, :focus_events) == true)},
      {:alternate_scroll, "\e[?1007h", &(input(&1, :alternate_scroll) == true)},
      {:synchronized_output, "\e[?2026h", &(Map.get(&1, :synchronized) == true)},
      {:reverse_wrap, "\e[?45h" <> String.duplicate("x", 25) <> "\e[2;1H\b",
       &(cursor(&1) == {0, 19})},
      {:reverse_wrap_stops_at_a_line_start, "\e[?45hab\e[2;1H\b", &(cursor(&1) == {1, 0})},
      {:mouse_x10, "\e[?9h", &(input(&1, :mouse) == 9)},
      {:mouse_utf8, "\e[?1005h", &(input(&1, :mouse_utf8) == true)},
      {:mouse_urxvt, "\e[?1015h", &(input(&1, :mouse_urxvt) == true)},
      {:mouse_pixels, "\e[?1016h", &(input(&1, :mouse_pixels) == true)},
      {:cursor_blink_mode, "\e[?12h", &(Map.get(&1, :cursor_blink) == true)},

      # Answers
      {:u7_cpr, "\e[2;3H\e[6n", &(replied(&1) == "\e[2;3R")},
      {:decxcpr, "\e[2;3H\e[?6n", &(replied(&1) == "\e[?2;3;1R")},
      {:u9_da1, "\e[c", &String.starts_with?(replied(&1), "\e[?")},
      {:rv_da2, "\e[>c", &String.starts_with?(replied(&1), "\e[>")},
      {:decreqtparm, "\e[0x", &(replied(&1) == "\e[2;1;1;128;128;1;0x")},
      {:da3, "\e[=c", &String.starts_with?(replied(&1), "\eP!|")},
      {:xr_xtversion, "\e[>0q", &String.starts_with?(replied(&1), "\eP>|guiltty")},
      {:decrqm_ansi, "\e[4$p", &(replied(&1) == "\e[4;2$y")},
      {:decrqm_dec, "\e[?2004h\e[?2004$p", &(replied(&1) == "\e[?2004;1$y")},
      {:decrqss_sgr, "\eP$qm\e\\", &(replied(&1) == "\eP1$r0m\e\\")},
      {:decrqss_decstbm, "\eP$qr\e\\", &(replied(&1) == "\eP1$r1;5r\e\\")},
      {:decrqcra, "x\e[1;1;1;1;1;1*y", &String.starts_with?(replied(&1), "\eP1!~")},
      {:xtgettcap, "\eP+q544e\e\\", &String.starts_with?(replied(&1), "\eP1+r544e=")},
      {:underline_color_has_no_side_effects, "\e[58;5;1m\e[58;2;1;2;3m\e[59m", &(&1.attrs == 0)},
      {:kitty_keyboard_query, "\e[?u", &(replied(&1) == "\e[?0u")},

      # OSC
      {:osc_title, "\e]2;one\a", &(&1.title == "one")},
      {:osc_st, "\e]2;one\e\\", &(&1.title == "one")},
      {:osc_icon, "\e]1;one\a", &(Map.get(&1, :icon_name) == "one")},
      {:initc_query, "\e]4;1;rgb:ab/cd/ef\e\\\e]4;1;?\a", &(replied(&1) =~ "rgb:abab/cdcd/efef")},
      {:oc_palette_reset, "\e]4;1;rgb:ab/cd/ef\e\\\e]104\e\\\e]4;1;?\a",
       &(replied(&1) =~ "4;1;rgb:")},
      {:osc7_cwd, "\e]7;file://h/tmp\a", &(Map.get(&1, :cwd_uri) == "file://h/tmp")},
      {:osc8_link, "\e]8;;https://x.y\aa\e]8;;\ab",
       &(Grid.link_at(&1, 0, 0) == "https://x.y" and Grid.link_at(&1, 0, 1) == nil)},
      {:osc10_fg, "\e]10;?\a", &(replied(&1) =~ ~r/^\e\]10;rgb:/)},
      {:osc11_bg, "\e]11;?\a", &(replied(&1) =~ ~r/^\e\]11;rgb:/)},
      {:cs_cursor_color, "\e]12;?\a", &(replied(&1) =~ ~r/^\e\]12;rgb:/)},
      {:cr_cursor_reset, "\e]12;#123456\a\e]112\a",
       &(Map.get(&1, :cursor_color) == nil and Map.has_key?(&1, :cursor_color))},
      {:osc110_reset, "\e]10;#123456\a\e]110\a",
       &(Map.get(&1, :fg_color) == nil and Map.has_key?(&1, :fg_color))},
      {:ms_clipboard, "\e]52;c;aGk=\a", &(Map.get(&1, :clipboard) == "hi")},
      {:osc133_prompt, "\e]133;A\a", &(Map.get(&1, :prompt_marks) not in [nil, []])},

      # Strings guiltty doesn't act on must never reach the screen
      {:dcs_consumed, "\ePjunk\e\\ok", &(line(&1) == "ok")},
      {:sos_consumed, "\eXjunk\e\\ok", &(line(&1) == "ok")},
      {:pm_consumed, "\e^junk\e\\ok", &(line(&1) == "ok")},
      {:unknown_apc_consumed, "\e_junk\e\\ok", &(line(&1) == "ok")},
      {:unknown_osc_consumed, "\e]999;junk\aok", &(line(&1) == "ok")},
      {:c1_csi, "\u009b2;3H", &(cursor(&1) == {1, 2} and line(&1) == "")},
      {:c1_osc, "\u009d2;one\u009cok", &(&1.title == "one" and line(&1) == "ok")},
      {:c1_dcs, "\u0090junk\u009cok", &(line(&1) == "ok")}
    ]
  end

  def get(id), do: Enum.find(all(), fn {case_id, _, _} -> case_id == id end)
  def ids, do: Enum.map(all(), &elem(&1, 0))
end

defmodule Guiltty.ConformanceTest do
  @moduledoc """
  A ratchet for v0.20.0 (book chapter 10, "Conformance").

  A case in `@known_gaps` must fail. When a change makes one pass, this test
  fails until it's taken off the list, so the list only ever gets shorter
  and always tells the truth.
  """
  use ExUnit.Case, async: true

  alias Guiltty.ConformanceCases, as: Cases
  alias Guiltty.{Grid, Parser, Terminal}

  @known_gaps []

  # Every capability in xterm-256color: a case that proves it, :input for
  # what the terminal sends rather than receives (see Guiltty.Keymap and the
  # keyboard tests), or a reason it's left out on purpose.
  @capabilities %{
    # Flags and numbers describing the terminal
    "OTbs" => :cub1,
    "am" => :am_xenl,
    "xenl" => :am_xenl,
    "bce" => :el,
    "ccc" => :initc_query,
    "mir" => :insert_mode,
    "msgr" => :cup,
    "npc" => :cub1,
    "AX" => :op,
    "XF" => :fe_fd_focus,
    "XT" => :osc_title,
    "colors" => :setaf,
    "pairs" => :setaf,
    "cols" => :cup,
    "lines" => :cup,
    "it" => :ht,
    "mc5i" => {:skip, "printer"},
    # Moving the cursor
    "cup" => :cup,
    "home" => :home,
    "cub" => :cub,
    "cub1" => :cub1,
    "cuf" => :cuf,
    "cuf1" => :cuf,
    "cuu" => :cuu,
    "cuu1" => :cuu,
    "cud" => :cud,
    "cud1" => :ind,
    "cr" => :cr,
    "hpa" => :hpa,
    "vpa" => :vpa,
    "nel" => :nel,
    "ind" => :ind,
    "ri" => :ri,
    "sc" => :sc_rc,
    "rc" => :sc_rc,
    "csr" => :csr,
    # Tabs
    "ht" => :ht,
    "hts" => :hts,
    "tbc" => :tbc,
    "cbt" => :cbt,
    # Editing
    "clear" => :clear,
    "ed" => :ed,
    "el" => :el,
    "el1" => :el1,
    "ech" => :ech,
    "ich" => :ich,
    "ich1" => :ich,
    "dch" => :dch,
    "dch1" => :dch,
    "il" => :il,
    "il1" => :il,
    "dl" => :dl,
    "dl1" => :dl,
    "indn" => :indn,
    "rin" => :rin,
    "rep" => :rep,
    "smir" => :insert_mode,
    "rmir" => :insert_mode,
    "smglr" => :decslrm,
    "smglp" => :decslrm,
    "smgrp" => :decslrm,
    "mgc" => :mgc,
    "meml" => {:skip, "HP memory lock: not in ctlseqs, and no program needs it"},
    "memu" => {:skip, "HP memory lock: not in ctlseqs, and no program needs it"},
    # Attributes and color
    "bold" => :bold,
    "dim" => :dim,
    "sitm" => :sitm,
    "ritm" => :ritm,
    "smul" => :smul,
    "rmul" => :rmul,
    "blink" => :blink,
    "rev" => :rev,
    "invis" => :invis,
    "smso" => :rev,
    "rmso" => :rmso,
    "smxx" => :smxx,
    "rmxx" => :rmxx,
    "sgr" => :sgr0,
    "sgr0" => :sgr0,
    "setaf" => :setaf,
    "setab" => :setab,
    "op" => :op,
    "initc" => :initc_query,
    "oc" => :oc_palette_reset,
    # Line drawing
    "acsc" => :smacs,
    "smacs" => :smacs,
    "rmacs" => :rmacs,
    # Modes
    "civis" => :civis,
    "cnorm" => :cnorm,
    "cvvis" => :cursor_blink_mode,
    "smam" => :smam_rmam,
    "rmam" => :smam_rmam,
    "smcup" => :title_stack,
    "rmcup" => :title_stack,
    "smkx" => :smkx,
    "rmkx" => :rmkx,
    "BE" => :be_bd,
    "BD" => :be_bd,
    "XM" => :xm_mouse,
    "Ss" => :cursor_style,
    "Se" => :cursor_style_reset,
    "E3" => :e3,
    "is2" => :is2_rs2,
    "rs2" => :is2_rs2,
    "rs1" => :rs1,
    "flash" => :flash_decscnm,
    "fe" => :fe_fd_focus,
    "fd" => :fe_fd_focus,
    "Cs" => :cs_cursor_color,
    "Cr" => :cr_cursor_reset,
    "Ms" => :ms_clipboard,
    "bel" => {:skip, "no grid effect to compare; covered by the bell tests"},
    "smm" => {:skip, "8-bit meta input: guiltty sends UTF-8 and ESC prefixes"},
    "rmm" => {:skip, "8-bit meta input: guiltty sends UTF-8 and ESC prefixes"},
    "mc0" => {:skip, "printer"},
    "mc4" => {:skip, "printer"},
    "mc5" => {:skip, "printer"},
    # Answers
    "u6" => :u7_cpr,
    "u7" => :u7_cpr,
    "u8" => :u9_da1,
    "u9" => :u9_da1,
    "RV" => :rv_da2,
    "XR" => :xr_xtversion,
    "rv" => :rv_da2,
    "xr" => :xr_xtversion,
    # Sent by the terminal, not to it
    "PS" => :input,
    "PE" => :input,
    "xm" => :input
  }

  defp grid_after(bytes) do
    {_parser, commands} = Parser.feed(Parser.new(), bytes)
    Terminal.apply(Grid.new(20, 5, screen_reports: true), commands)
  end

  # Only the terminfo names matter here: each line of `infocmp -1x` is
  # `name=value,`, `name#value,` or `name,`.
  defp terminfo_names do
    "test/fixtures/terminfo/xterm-256color.txt"
    |> File.read!()
    |> String.split("\n", trim: true)
    |> Enum.filter(&String.starts_with?(&1, "\t"))
    |> Enum.map(fn line -> line |> String.trim() |> String.split(~r/[=#,]/) |> hd() end)
  end

  for id <- Cases.ids() do
    @id id
    test "#{id}" do
      {id, bytes, check} = Cases.get(@id)
      passed = check.(grid_after(bytes)) == true

      if id in @known_gaps do
        refute passed, "#{id} passes now: take it off @known_gaps"
      else
        assert passed,
               "#{id} is wrong: #{inspect(bytes)} -> #{inspect(Grid.dump(grid_after(bytes)))}"
      end
    end
  end

  test "known gaps are all real cases" do
    assert @known_gaps -- Cases.ids() == []
  end

  describe "refused on purpose: the answers arrive at the program as if you typed them" do
    defp refused(bytes) do
      {_parser, commands} = Parser.feed(Parser.new(), bytes)
      Terminal.apply(Grid.new(20, 5), commands)
    end

    test "DECRQCRA, unless asked for: it lets a program read the screen" do
      assert refused("x\e[1;1;1;1;1;1*y").responses == []
    end

    test "reading the title: any program can choose it, a command and a newline" do
      assert refused("\e]2;one\a\e[21t").responses == []
      assert refused("\e]1;one\a\e[20t").responses == []
    end

    test "reading the clipboard" do
      grid = refused("\e]52;c;?\a")
      assert grid.responses == [] and grid.clipboard == nil
    end

    test "resizing, moving and iconifying the window" do
      grid = refused("\e[8;40;100t\e[3;10;10t\e[2t\e[9;1t")
      assert {grid.cols, grid.rows, grid.responses} == {20, 5, []}
    end
  end

  describe "the xterm-256color promises" do
    test "every capability is accounted for" do
      names = terminfo_names()
      keys = Enum.filter(names, &String.starts_with?(&1, "k"))

      assert (names -- keys) -- Map.keys(@capabilities) == [],
             "add these to @capabilities: a case, :input, or a reason to skip"
    end

    test "no capability is listed that the entry doesn't have" do
      assert Map.keys(@capabilities) -- terminfo_names() == []
    end

    test "every capability points at a case that exists" do
      for {name, what} <- @capabilities, is_atom(what), what != :input do
        assert what in Cases.ids(), "#{name} points at #{what}, which isn't a case"
      end
    end
  end
end
