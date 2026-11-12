defmodule Fsrs.ModelV6 do
  @moduledoc false

  # FSRS-6 scalar model. Mirrors `src/model_v6.rs` of fsrs-rs.
  # `w` is the clipped 21-parameter tuple.

  import Fsrs.Math, only: [clamp: 3]

  alias Fsrs.MemoryState

  @s_min Fsrs.Math.s_min()
  @s_max Fsrs.Math.s_max()
  @d_min Fsrs.Math.d_min()
  @d_max Fsrs.Math.d_max()

  def forgetting_curve(w, t, s) do
    s = max(s, @s_min)
    decay = -elem(w, 20)
    factor = :math.pow(0.9, 1.0 / decay) - 1.0
    # FSRS-6 works on whole days.
    t = Float.round(max(t, 0.0) * 1.0)
    :math.pow(t / s * factor + 1.0, decay)
  end

  def next_interval(w, stability, desired_retention) do
    stability = max(stability, @s_min)
    desired_retention = clamp(desired_retention, 0.0001, 0.9999)
    decay = -elem(w, 20)
    factor = :math.pow(0.9, 1.0 / decay) - 1.0

    clamp(
      stability / factor * (:math.pow(desired_retention, 1.0 / decay) - 1.0),
      0.0,
      @s_max
    )
  end

  defp stability_after_success(w, s, r, d, rating) do
    hard_penalty = if rating == 2, do: elem(w, 15), else: 1.0
    easy_bonus = if rating == 4, do: elem(w, 16), else: 1.0

    clamp(
      s *
        (:math.exp(elem(w, 8)) *
           (11.0 - d) *
           :math.pow(s, -elem(w, 9)) *
           (:math.exp((1.0 - r) * elem(w, 10)) - 1.0) *
           hard_penalty *
           easy_bonus + 1.0),
      @s_min,
      @s_max
    )
  end

  defp stability_after_failure(w, s, r, d) do
    new_s_min = s / :math.exp(elem(w, 17) * elem(w, 18))

    new_s =
      elem(w, 11) * :math.pow(d, -elem(w, 12)) *
        (:math.pow(s + 1.0, elem(w, 13)) - 1.0) *
        :math.exp((1.0 - r) * elem(w, 14))

    clamp(min(new_s, new_s_min), @s_min, @s_max)
  end

  defp stability_short_term(w, s, rating) do
    sinc =
      :math.exp(elem(w, 17) * (rating - 3.0 + elem(w, 18))) * :math.pow(s, -elem(w, 19))

    new_s = s * if(rating >= 2, do: max(sinc, 1.0), else: sinc)
    clamp(new_s, @s_min, @s_max)
  end

  def init_difficulty(w, rating) do
    elem(w, 4) - :math.exp(elem(w, 5) * max(rating - 1, 0)) + 1.0
  end

  defp next_difficulty(w, d, rating) do
    delta_d = -elem(w, 6) * (rating - 3.0)
    new_d = d + (10.0 - d) / 9.0 * delta_d
    w7 = elem(w, 7)

    clamp(w7 * init_difficulty(w, 4) + (1.0 - w7) * new_d, @d_min, @d_max)
  end

  def next_state(w, %MemoryState{} = state, delta_t, rating) do
    rating = clamp(rating, 1, 4)
    delta_t = Float.round(max(delta_t, 0.0) * 1.0)
    s = clamp(state.stability, @s_min, @s_max)
    d = clamp(state.difficulty, @d_min, @d_max)
    r = forgetting_curve(w, delta_t, s)

    stability =
      cond do
        delta_t == 0.0 -> stability_short_term(w, s, rating)
        rating == 1 -> stability_after_failure(w, s, r, d)
        true -> stability_after_success(w, s, r, d, rating)
      end

    %MemoryState{
      stability: stability,
      difficulty: next_difficulty(w, d, rating),
      stability_fast: stability
    }
  end

  def memory_state_from_sm2(w, ease_factor, interval, sm2_retention) do
    decay = -elem(w, 20)
    factor = :math.pow(0.9, 1.0 / decay) - 1.0
    w9 = elem(w, 9)
    recall_term = :math.exp(elem(w, 8)) * (:math.exp((1.0 - sm2_retention) * elem(w, 10)) - 1.0)

    {stability, difficulty} =
      case pow_or_infinity(sm2_retention, 1.0 / decay) do
        # In fsrs-rs the division by infinity yields a zero stability, which
        # in turn pushes difficulty to its maximum unless `w9` is zero.
        :infinity when w9 == 0.0 ->
          {0.0, 11.0 - (ease_factor - 1.0) / recall_term}

        :infinity ->
          {0.0, 11.0}

        power ->
          stability = max(interval, @s_min) * factor / (power - 1.0)

          {stability, 11.0 - (ease_factor - 1.0) / (recall_term * :math.pow(stability, -w9))}
      end

    {:ok,
     %MemoryState{
       stability: stability,
       difficulty: clamp(difficulty, @d_min, @d_max),
       stability_fast: stability
     }}
  rescue
    # fsrs-rs reports non-finite results as `InvalidInput`; the BEAM raises instead.
    ArithmeticError -> {:error, :invalid_input}
  end

  # `base ** exponent` for a negative exponent, returning `:infinity` where
  # IEEE arithmetic would (a zero or vanishing base in `0..1`).
  defp pow_or_infinity(base, _exponent) when base == 0, do: :infinity

  defp pow_or_infinity(base, exponent) do
    :math.pow(base, exponent)
  rescue
    ArithmeticError ->
      if base > 0 and base < 1, do: :infinity, else: reraise(ArithmeticError, __STACKTRACE__)
  end
end
