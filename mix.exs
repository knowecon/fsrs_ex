defmodule Fsrs.MixProject do
  use Mix.Project

  def project do
    # Tracks the fsrs-rs version this package is ported from.
    version = "7.0.0"

    [
      app: :fsrs_ex,
      version: version,
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      description: description(),
      package: package(),
      source_url: "https://github.com/lulucatdev/fsrs_ex",
      homepage_url: "https://github.com/lulucatdev/fsrs_ex",
      docs: [
        main: "readme",
        source_ref: "v#{version}",
        extras: [
          "README.md",
          "guides/GETTING_STARTED.md",
          "guides/MIGRATING_TO_7.md",
          "guides/PORTING_POLICY.md",
          "guides/PARITY_TESTING.md",
          "guides/RELEASE_PROCESS.md",
          "LICENSE",
          "LICENSE-fsrs-rs"
        ],
        groups_for_extras: [
          Guides: Path.wildcard("guides/*.md")
        ],
        groups_for_modules: [
          "Core API": [Fsrs],
          "Data Structures": [
            Fsrs.MemoryState,
            Fsrs.NextStates,
            Fsrs.ItemState,
            Fsrs.Item,
            Fsrs.Review,
            Fsrs.Rating
          ]
        ]
      ],
      deps: deps()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp description do
    "Elixir port of the open-spaced-repetition/fsrs-rs scheduler (FSRS-7 and FSRS-6)."
  end

  defp package do
    [
      name: "fsrs_ex",
      maintainers: ["lulucatdev"],
      licenses: ["MIT", "BSD-3-Clause"],
      files: [
        "lib",
        "guides",
        "mix.exs",
        "Makefile",
        "llms.txt",
        "README.md",
        "LICENSE",
        "LICENSE-fsrs-rs",
        "test/fixtures/rust_fixture/Cargo.toml",
        "test/fixtures/rust_fixture/Cargo.lock",
        "test/fixtures/rust_fixture/src",
        "test/fixtures/fsrs_rs_v7_0_0_fixture.json.gz"
      ],
      links: %{
        "GitHub" => "https://github.com/lulucatdev/fsrs_ex",
        "fsrs-rs" => "https://github.com/open-spaced-repetition/fsrs-rs",
        "FSRS Algorithm Wiki" =>
          "https://github.com/open-spaced-repetition/fsrs4anki/wiki/The-Algorithm",
        "Jarrett Ye (X)" => "https://x.com/JarrettYe"
      }
    ]
  end

  defp deps do
    [
      {:ex_doc, ">= 0.0.0", only: :dev, runtime: false}
    ]
  end
end
