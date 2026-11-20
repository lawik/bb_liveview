# SPDX-FileCopyrightText: 2025 James Harton
#
# SPDX-License-Identifier: Apache-2.0

defmodule BB.LiveView.MixProject do
  use Mix.Project

  @moduledoc """
  Interactive LiveView-based dashboard for Beam Bots-powered robots.
  """

  @version "0.3.4"

  def project do
    [
      aliases: aliases(),
      app: :bb_liveview,
      consolidate_protocols: Mix.env() == :prod,
      deps: deps(),
      description: @moduledoc,
      dialyzer: dialyzer(),
      docs: docs(),
      elixir: "~> 1.19",
      elixirc_paths: elixirc_paths(Mix.env()),
      listeners: listeners(Mix.env()),
      package: package(),
      start_permanent: Mix.env() == :prod,
      version: @version
    ]
  end

  defp listeners(:dev), do: [Phoenix.CodeReloader]
  defp listeners(_), do: []

  def application, do: application(Mix.env())

  def application(:dev) do
    [
      extra_applications: [:logger],
      mod: {Dev.Application, []}
    ]
  end

  def application(_) do
    [
      extra_applications: [:logger]
    ]
  end

  defp dialyzer, do: [plt_add_apps: [:ex_unit, :mix]]

  defp package do
    [
      maintainers: ["James Harton <james@harton.nz>"],
      licenses: ["Apache-2.0"],
      links: %{
        "Source" => "https://github.com/beam-bots/bb_liveview",
        "Sponsor" => "https://github.com/sponsors/jimsynz"
      },
      files: ~w(
        lib
        priv/static
        mix.exs
        README.md
        CHANGELOG.md
        LICENSE*
        LICENSES
        usage-rules.md
      )
    ]
  end

  defp docs do
    [
      main: "readme",
      logo: "assets/logo.png",
      extras:
        ["README.md", "CHANGELOG.md"]
        |> Enum.concat(Path.wildcard("documentation/**/*.{md,livemd,cheatmd}")),
      groups_for_extras: [
        Tutorials: ~r/tutorials\//,
        "How-to Guides": ~r/how-to\//
      ],
      source_ref: "main",
      source_url: "https://github.com/beam-bots/bb_liveview"
    ]
  end

  defp aliases do
    [
      "assets.setup": ["cmd --cd assets npm install"],
      "assets.build": [
        "cmd --cd assets npm run build",
        "cmd --cd assets npm run build:css"
      ],
      "assets.deploy": [
        "cmd --cd assets npm run build -- --minify",
        "cmd --cd assets npm run build:css"
      ]
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:bb, bb_dep("~> 0.31 and >= 0.31.1")},
      # Igniter and phx_install are dev/test-only here — the bb_liveview
      # installer ships their declarations to consumer projects via
      # `adds_deps:` in `Mix.Tasks.BbLiveview.Install.info/2`. We carry them
      # here only so our own installer tests can exercise the
      # phx.install.* compositions.
      {:igniter, "~> 0.7 and >= 0.7.3", only: [:dev, :test], runtime: false},
      {:jason, "~> 1.4"},
      # Plays `BB.LiveView.VideoSource` streams in the Images tab over WebRTC.
      # Without it, video sources are ignored.
      {:membrane_webrtc_plugin, "~> 0.26", optional: true},
      {:phoenix_live_view, "~> 1.0"},
      {:phx_install, "~> 0.1", only: [:dev, :test], runtime: false},
      {:plug, "~> 1.16"},

      # Build tools (dev only)
      # Optional rather than dev-only: membrane_webrtc_plugin needs it in
      # every environment, but consumers shouldn't inherit it from us.
      {:bandit, "~> 1.0", optional: true},
      {:esbuild, "~> 0.8", runtime: Mix.env() == :dev},
      {:phoenix_live_reload, "~> 1.5", only: :dev},

      # dev/test
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:ex_check, "~> 0.16", only: [:dev, :test], runtime: false},
      {:ex_doc, ">= 0.0.0", only: [:dev, :test], runtime: false},
      {:floki, "~> 0.36", only: :test},
      {:git_ops, "~> 2.9", only: [:dev, :test], runtime: false},
      {:mimic, "~> 2.2", only: :test, runtime: false},
      {:mix_audit, "~> 2.1", only: [:dev, :test], runtime: false},
      {:phoenix_test, "~> 0.9", only: :test},
      {:usage_rules, "~> 1.2", only: [:dev], runtime: false}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support", "dev"]
  defp elixirc_paths(:dev), do: ["lib", "test/support", "dev"]
  defp elixirc_paths(_), do: ["lib"]

  defp bb_dep(default) do
    case System.get_env("BB_VERSION") do
      nil -> default
      "local" -> [path: "../bb", override: true]
      "main" -> [git: "https://github.com/beam-bots/bb.git", override: true]
      version -> "~> #{version}"
    end
  end
end
