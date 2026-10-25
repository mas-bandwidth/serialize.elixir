defmodule Serialize.MixProject do
  use Mix.Project

  def project do
    [
      app: :serialize,
      version: "2.0.0",
      elixir: "~> 1.20",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      dialyzer: dialyzer()
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_env), do: ["lib"]

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger]
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      # Dialyzer, the port's strictest static lens. Pinned exactly; mix.lock
      # carries the package checksum. Never a runtime dependency, and dev only:
      # MIX_ENV=test builds (the suite, the nightly conformance job) need no
      # deps.get.
      {:dialyxir, "== 1.4.8", only: :dev, runtime: false}
    ]
  end

  # The PLT lives in priv/plts so CI can cache it (keyed on OTP, Elixir and
  # mix.lock). Every flag here is a warning class mix dialyzer reports; the
  # job runs with zero warnings and no ignore file.
  defp dialyzer do
    [
      plt_local_path: "priv/plts",
      plt_core_path: "priv/plts",
      flags: [:error_handling, :extra_return, :missing_return, :unmatched_returns]
    ]
  end
end
