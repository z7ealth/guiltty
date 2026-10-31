defmodule Guiltty.ReleaseTest do
  # The release step that keeps the node's cookie off the command line
  # (mix.exs, private_cookie/1; book chapter 20), on a made-up release.
  use ExUnit.Case, async: true

  @moduletag :tmp_dir

  defp fake_release(dir, script) do
    File.mkdir_p!(Path.join(dir, "bin"))
    File.mkdir_p!(Path.join(dir, "releases"))
    File.write!(Path.join([dir, "bin", "guiltty"]), script)
    File.write!(Path.join([dir, "releases", "COOKIE"]), "SECRET")
    %{path: dir, name: :guiltty}
  end

  test "removes every --cookie and empties the COOKIE file", %{tmp_dir: dir} do
    script = """
    exec "$REL_VSN_DIR/elixir" \\
         --hidden --cookie "$RELEASE_COOKIE" \\
         --rpc-eval "$RELEASE_NODE" "$1"
    exec "$REL_VSN_DIR/$REL_EXEC" \\
         --cookie "$RELEASE_COOKIE" \\
         --vm-args "$RELEASE_VM_ARGS" "$@"
    """

    release = fake_release(dir, script)
    assert Guiltty.MixProject.private_cookie(release) == release

    refute File.read!(Path.join([dir, "bin", "guiltty"])) =~ "cookie"
    cookie = Path.join([dir, "releases", "COOKIE"])
    assert File.read!(cookie) == ""
    assert File.stat!(cookie).mode |> Bitwise.band(0o777) == 0o600
  end

  test "fails the build if Mix writes the script some other way", %{tmp_dir: dir} do
    release = fake_release(dir, ~s(exec erl -setcookie "$RELEASE_COOKIE"\n))
    assert_raise Mix.Error, fn -> Guiltty.MixProject.private_cookie(release) end
  end

  test "the release templates keep distribution on localhost" do
    for file <- ["rel/vm.args.eex", "rel/remote.vm.args.eex"],
        do: assert(File.read!(file) =~ "-kernel inet_dist_use_interface {127,0,0,1}")

    assert File.read!("rel/env.sh.eex") =~ ~s(RELEASE_NODE="${RELEASE_NODE:-guiltty@127.0.0.1}")
  end
end
