# Getting Started

## Installation

Add `fsrs_ex` to your `mix.exs` dependencies:

```elixir
def deps do
  [
    {:fsrs_ex, "~> 7.0"}
  ]
end
```

Then fetch:

```bash
mix deps.get
```

## The model

Create a model once and reuse it. Without arguments you get FSRS-7 with the default parameters:

```elixir
fsrs = Fsrs.default()
```

Pass your own parameters (for example from the fsrs-rs optimizer) with `Fsrs.new/1`. The parameter count selects the algorithm: 34 for FSRS-7, 21 for FSRS-6.

```elixir
{:ok, fsrs} = Fsrs.new(my_parameters)
```

## What to store per card

`fsrs_ex` does not have a card struct. Store these with each card yourself:

- the `Fsrs.MemoryState` (three floats: `stability`, `difficulty`, `stability_fast`), or `nil` for a card that was never reviewed
- the time of the last review
- the due time you derived from the interval

## Reviewing a card

`Fsrs.next_states/4` returns the outcome for all four ratings, so you can show the intervals on the answer buttons before the user chooses.

```elixir
defmodule MyApp.Review do
  @desired_retention 0.9

  def answer(fsrs, card, rating, now \\ DateTime.utc_now()) do
    elapsed_days =
      case card.last_review do
        nil -> 0.0
        last_review -> DateTime.diff(now, last_review, :second) / 86_400
      end

    {:ok, next_states} =
      Fsrs.next_states_with_elapsed_days(
        fsrs,
        card.memory_state,
        @desired_retention,
        elapsed_days
      )

    chosen = Fsrs.NextStates.fetch!(next_states, rating)

    # The interval is in fractional days. Rounding, a minimum and a maximum
    # are application policy.
    interval_days = chosen.interval |> round() |> max(1) |> min(36_500)

    %{
      card
      | memory_state: chosen.memory,
        last_review: now,
        due: DateTime.add(now, interval_days, :day)
    }
  end
end
```

Ratings are `:again`, `:hard`, `:good`, `:easy`, or the integers `1..4`.

With FSRS-7 the `:again` interval of a new or freshly failed card can be seconds or minutes. If you prefer fixed learning steps for such cards, apply them in your application and keep using the `memory` from `next_states`.

## Retrievability

The probability of recalling a card after some time:

```elixir
Fsrs.current_retrievability(fsrs, card.memory_state, elapsed_days)
# => a float between 0.0 and 1.0
```

The number of days until it drops to 90%:

```elixir
Fsrs.s90(fsrs, card.memory_state)
```

With FSRS-7, `memory_state.stability` is an internal quantity and does not equal this value.

## Rebuilding state from history

Replay a card's reviews to compute its memory state. `delta_t` is the number of days since the previous review and must be `0` for the first one.

```elixir
item = Fsrs.Item.new([{:good, 0}, {:good, 3.2}, {:again, 9.0}, {:good, 0.01}])

{:ok, memory_state} = Fsrs.memory_state(fsrs, item)
{:ok, states_after_each_review} = Fsrs.historical_memory_states(fsrs, item)
```

For a card whose history is incomplete, approximate a starting state from its current interval:

```elixir
{:ok, memory_state} = Fsrs.memory_state_from_sm2(fsrs, 2.5, 30.0, 0.9)
```

## Errors

Functions that can fail return `{:ok, value}` or `{:error, reason}`:

- `:invalid_parameters` — wrong parameter count or a non-numeric parameter
- `:invalid_input` — inputs for which the result is undefined (for example `sm2_retention` outside `0..1`)

## Next Steps

- `Fsrs` module docs for the full API
- [Migrating to 7.0](MIGRATING_TO_7.md) if you used 0.1.x
- [Porting Policy](PORTING_POLICY.md) for upstream alignment details
- [Parity Testing](PARITY_TESTING.md) for Rust-vs-Elixir verification
