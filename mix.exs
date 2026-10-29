defmodule Guiltty.MixProject do
  use Mix.Project

  def project do
    [
      app: :guiltty,
      version: "0.1.0",
      elixir: "~> 1.20",
      start_permanent: Mix.env() == :prod,
      compilers: [:elixir_make] ++ Mix.compilers(),
      make_clean: ["clean"],
      deps: deps(),
      releases: [
        # Temporary: when guiltty stops (window closed or shell exited), the
        # VM isn't brought down as a crash. Guiltty.Application.stop/1 then
        # stops it cleanly.
        guiltty: [applications: [guiltty: :temporary]]
      ]
    ]
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
      {:elixir_make, "~> 0.10.1", runtime: false}
    ]
  end
end
