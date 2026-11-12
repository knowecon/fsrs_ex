# Parity Testing

This guide describes how the Elixir implementation is verified against the Rust baseline.

## Files

- Generator: `test/fixtures/rust_fixture` — a Rust program that depends on `fsrs = "=7.0.0"` from crates.io
- Fixture: `test/fixtures/fsrs_rs_v7_0_0_fixture.json.gz`
- Tests: `test/fsrs_rs_parity_test.exs`

## Requirements

- A Rust toolchain with `cargo` (only to regenerate the fixture; running the tests needs Elixir alone)

## Regenerate the Fixture

```bash
make fixture
```

This runs the generator with the versions pinned in its `Cargo.lock` and compresses the output. The generator is deterministic, so regenerating without changes reproduces the committed file.

## Run Parity Tests

```bash
mix test test/fsrs_rs_parity_test.exs
```

## What Is Compared

For seven parameter sets (FSRS-7 default and custom, FSRS-6 default and custom, a 19-parameter and a 17-parameter set, and the empty default):

- parameter filling and model version selection, including rejected parameter counts
- `current_retrievability` over a grid of states and elapsed times
- `interval_at_retrievability`, `next_interval_for_state`, `s90` and `next_interval`
- `next_states` for new cards and `next_states_with_elapsed_days` over states, retentions and fractional elapsed times
- `memory_state` and `historical_memory_states` for review histories, with and without a starting state
- `memory_state_from_sm2`, including inputs that fsrs-rs rejects
- simulated walks of 100 reviews that feed each result back in, which reach very small and very large stabilities

## Tolerance

fsrs-rs computes in `f32` and fsrs_ex in 64-bit floats, so values are compared with a relative tolerance of `5.0e-4`. Most values agree to about `1.0e-6`. The largest differences, about `2.4e-4`, occur where `f32` loses precision in a subtraction of nearly equal numbers, for example with stabilities of a few thousandths of a day.

Inputs in the fixture are written as the shortest decimal for each `f32`, so that fsrs_ex receives `0.9` where the Rust code received `0.9f32`.

## When to Re-run

- after any change to the model code or parameter handling
- before every release
