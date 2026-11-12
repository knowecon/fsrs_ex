# fsrs_ex (Fsrs)

> Elixir port of the scheduler in [`open-spaced-repetition/fsrs-rs`](https://github.com/open-spaced-repetition/fsrs-rs) `v7.0.0` (FSRS-7, with FSRS-6 and earlier still supported).
>
> 中文说明：这是 `fsrs-rs v7.0.0` 调度（推理）部分的 Elixir 移植，支持 FSRS-7，也保留 FSRS-6 及更早版本。

`fsrs_ex` computes memory states, retrievability and review intervals. Its results are checked against values recorded from the Rust crate.

The version number of `fsrs_ex` follows the version of `fsrs-rs` it is ported from.

> **Upgrading from 0.1.x?** Version 7 is a breaking rewrite: the baseline moved from `py-fsrs` to `fsrs-rs`, and `Scheduler`, `Card` and `ReviewLog` are gone. See [Migrating to 7.0](guides/MIGRATING_TO_7.md).

## What it covers

| fsrs-rs | fsrs_ex |
|---|---|
| `FSRS::new`, `FSRS::default`, `version` | `Fsrs.new/1`, `Fsrs.default/0`, `Fsrs.version/1` |
| `next_states`, `next_states_with_elapsed_days` | `Fsrs.next_states/4`, `Fsrs.next_states_with_elapsed_days/4` |
| `memory_state`, `historical_memory_states` (and batch forms) | same names |
| `memory_state_from_sm2` | `Fsrs.memory_state_from_sm2/4` |
| `current_retrievability`, `s90`, `interval_at_retrievability`, `next_interval_for_state`, `next_interval` | same names |
| `check_and_fill_parameters`, default parameter constants | same names |
| `MemoryState`, `NextStates`, `ItemState`, `FSRSItem`, `FSRSReview` | `Fsrs.MemoryState`, `Fsrs.NextStates`, `Fsrs.ItemState`, `Fsrs.Item`, `Fsrs.Review` |

Not ported: the optimizer (`compute_parameters`), model evaluation, the simulator and cost-ADR.

`fsrs_ex` is a model, not a full scheduler. Due dates, learning steps, interval rounding, fuzzing and a maximum interval are the application's job, as they are for users of `fsrs-rs`.

## Installation

```elixir
def deps do
  [
    {:fsrs_ex, "~> 7.0"}
  ]
end
```

Requires Elixir 1.18 or later. There are no runtime dependencies.

## Quick Start

```elixir
fsrs = Fsrs.default()          # FSRS-7 with default parameters
desired_retention = 0.9

# New card: no memory state yet.
{:ok, next_states} = Fsrs.next_states(fsrs, nil, desired_retention, 0)

# The user pressed "Good".
chosen = next_states.good
chosen.memory    # %Fsrs.MemoryState{stability: ..., difficulty: ..., stability_fast: ...}
chosen.interval  # fractional days until retrievability drops to 0.9

# Store chosen.memory with the card. At the next review:
{:ok, next_states} = Fsrs.next_states(fsrs, chosen.memory, desired_retention, 5)
```

`next_states/4` takes whole days. For same-day or otherwise fractional gaps use `Fsrs.next_states_with_elapsed_days/4`.

Chinese note: 应用需要保存的是 `Fsrs.MemoryState`（三个数）和上次复习时间；间隔取整和到期时间由应用自己计算。

## Choosing a model

The number of parameters selects the algorithm:

| Parameters | Model |
|---|---|
| none, or 34 | FSRS-7 |
| 21 | FSRS-6 |
| 19 | FSRS-5 (expanded to 21) |
| 17 | FSRS-4.5 (expanded to 21) |

```elixir
{:ok, fsrs7} = Fsrs.new()
{:ok, fsrs6} = Fsrs.new(Fsrs.fsrs6_default_parameters())
{:error, :invalid_parameters} = Fsrs.new([1.0, 2.0])
```

Out-of-range parameters are clipped, as in `fsrs-rs`, rather than rejected.

## What is different in FSRS-7

- **A second stability value.** `Fsrs.MemoryState` has `stability_fast` next to `stability`, and the forgetting curve mixes a fast and a slow power curve.
- **Stability is no longer the 90% interval.** Use `Fsrs.s90/2` when you need "days until retrievability is 90%".
- **Fractional days.** Elapsed time is used as is, so a review ten minutes later and one ten days later go through the same formulas. FSRS-6 rounds to whole days.
- **34 parameters** instead of 21.

## Numerical parity

`fsrs-rs` computes in 32-bit floats; `fsrs_ex` uses the BEAM's 64-bit floats. Results therefore agree closely but not bit for bit: across the recorded cases every value is within 0.05% of the Rust output, and the largest observed difference is about 0.024%.

The parity fixture and its generator are in this repository:

- generator: `test/fixtures/rust_fixture` (a small Rust program depending on `fsrs = "=7.0.0"`)
- fixture: `test/fixtures/fsrs_rs_v7_0_0_fixture.json.gz`
- tests: `test/fsrs_rs_parity_test.exs`

```bash
make fixture   # needs cargo
mix test
```

More details: `guides/PARITY_TESTING.md`.

## Release Automation (Makefile)

```bash
make help
make preflight
make publish-interactive
```

For CI or non-interactive publishing:

```bash
export HEX_API_KEY=...
make release
```

See `guides/RELEASE_PROCESS.md`.

## License

`fsrs_ex` is released under the MIT License (`LICENSE`). It is a port of `fsrs-rs`, which is distributed under the BSD 3-Clause License; that license and copyright notice are reproduced in `LICENSE-fsrs-rs`.

## HexDocs

- Package: https://hex.pm/packages/fsrs_ex
- Docs: https://hexdocs.pm/fsrs_ex
