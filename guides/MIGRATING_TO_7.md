# Migrating to 7.0

Version 7.0.0 is a breaking rewrite. The 0.1.x series ported `py-fsrs` (FSRS-6). From 7.0.0 on, `fsrs_ex` ports the scheduler of `fsrs-rs` and uses its version numbers.

中文说明：7.0.0 是破坏性重写。0.1.x 移植的是 `py-fsrs`，7.0.0 起改为移植 `fsrs-rs` 并沿用它的版本号。

## What was removed

`py-fsrs` is a complete scheduler; `fsrs-rs` is a model. The parts that only exist in `py-fsrs` are gone:

| 0.1.x | 7.0 |
|---|---|
| `Scheduler`, `new_scheduler` | `Fsrs.new/1` — parameters only |
| `Card`, card states `:learning`, `:review`, `:relearning` | `Fsrs.MemoryState`; keep due dates and any learning state in your own schema |
| `ReviewLog` | `Fsrs.Review` (`rating` and `delta_t` in days) |
| `review_card` | `Fsrs.next_states/4` or `Fsrs.next_states_with_elapsed_days/4` |
| `reschedule_card` | `Fsrs.memory_state/3` |
| `get_card_retrievability` | `Fsrs.current_retrievability/3` |
| `learning_steps`, `relearning_steps` | not provided |
| `enable_fuzzing`, `maximum_interval` | not provided |
| `desired_retention` scheduler option | argument of `next_states` |
| `to_dict`, `from_dict`, `to_json`, `from_json` | not provided; the structs are plain data |
| `State` | removed |
| `jason` dependency | removed |

`Fsrs.default_parameters/0` now returns the 34 FSRS-7 parameters as a list. The FSRS-6 defaults are `Fsrs.fsrs6_default_parameters/0`.

Parameters outside their valid range used to raise. They are now clipped, as in `fsrs-rs`.

See [Getting Started](GETTING_STARTED.md) for a review function that replaces `review_card`.

## Existing cards

A 0.1.x card has `stability` and `difficulty` from FSRS-6. There are three ways forward.

### Replay the review history (recommended)

If you kept review logs, recompute each card's state under FSRS-7:

```elixir
fsrs = Fsrs.default()

reviews =
  logs
  |> Enum.sort_by(& &1.review_datetime, DateTime)
  |> Enum.map_reduce(nil, fn log, previous ->
    delta_t =
      if previous, do: DateTime.diff(log.review_datetime, previous, :second) / 86_400, else: 0

    {{log.rating, delta_t}, log.review_datetime}
  end)
  |> elem(0)

{:ok, memory_state} = Fsrs.memory_state(fsrs, Fsrs.Item.new(reviews))
```

### Stay on FSRS-6

A 21-parameter model keeps using FSRS-6, and old values carry over directly:

```elixir
fsrs = Fsrs.new!(Fsrs.fsrs6_default_parameters())

memory_state = %Fsrs.MemoryState{
  stability: card.stability,
  difficulty: card.difficulty,
  stability_fast: card.stability
}
```

Results will not be identical to 0.1.x. The FSRS-6 of `fsrs-rs` rounds elapsed time to the nearest day where `py-fsrs` truncated it, uses a lower stability floor (`0.0001` instead of `0.001`), and returns unrounded intervals.

### Convert without history

Without review logs, an FSRS-7 state can be approximated from the old stability, which under FSRS-6 is the interval at 90% retrievability:

```elixir
{:ok, memory_state} = Fsrs.memory_state_from_sm2(Fsrs.default(), 2.5, card.stability, 0.9)
```

This keeps the card's 90% interval and resets its difficulty to the neutral value. It is an approximation built on the SM-2 bridge of `fsrs-rs`, not a conversion defined by upstream.

## Behavior to be aware of

- **`stability` changed meaning.** Under FSRS-7 it is not the 90% interval. Anything that displayed or sorted by stability should use `Fsrs.s90/2`.
- **Intervals are fractional days**, not rounded and not capped. Apply your own rounding, minimum and maximum.
- **Elapsed time is fractional** under FSRS-7. Pass the real elapsed days, including for same-day reviews.
- **No UTC check.** The library no longer sees datetimes; compute elapsed days however your application defines them.
