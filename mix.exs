defmodule Guiltty.MixProject do
  use Mix.Project

  def project do
    [
      app: :guiltty,
      version: "0.12.4",
      elixir: "~> 1.20",
      start_permanent: Mix.env() == :prod,
      compilers: [:elixir_make] ++ Mix.compilers(),
      make_clean: ["clean"],
      deps: deps(),
      releases: [
        # Temporary: when guiltty stops (window closed or shell exited), the
        # VM isn't brought down as a crash. Guiltty.Application.stop/1 then
        # stops it cleanly.
        guiltty: [applications: [guiltty: :temporary], steps: [:assemble, &private_cookie/1]]
      ]
    ]
  end

  # The start script Mix writes passes the cookie with --cookie, which puts
  # it on the VM's command line, where every user on the machine can read
  # it (ps, /proc/*/cmdline). Without the flag, Erlang reads
  # ~/.erlang.cookie, which it creates if needed and refuses to use unless
  # only you can read it. So the flag goes, and the COOKIE file Mix wrote,
  # which nothing reads any more, is emptied. Book chapter 20.
  @doc false
  def private_cookie(release) do
    script = Path.join([release.path, "bin", to_string(release.name)])
    text = File.read!(script)
    stripped = String.replace(text, ~s(--cookie "$RELEASE_COOKIE"), "")

    if stripped == text or stripped =~ "--cookie" do
      Mix.raise("#{script} doesn't pass --cookie as expected: check private_cookie/1 in mix.exs")
    end

    File.write!(script, stripped)
    cookie = Path.join([release.path, "releases", "COOKIE"])
    File.write!(cookie, "")
    File.chmod!(cookie, 0o600)
    release
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger],
      mod: {Guiltty.Application, []}
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:elixir_make, "~> 0.10.1", runtime: false},
      {:telemetry, "~> 1.4"},
      {:stream_data, "~> 1.4", only: :test}
    ]
  end
end
