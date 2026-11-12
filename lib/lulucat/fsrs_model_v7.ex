defmodule Fsrs.ModelV7 do
  @moduledoc false

  # FSRS-7 dual-trace scalar model. Mirrors `src/model_v7.rs` of fsrs-rs.
  # `w` is the clipped 34-parameter tuple.
  #
  # Parameter layout:
  #   w0..w3    initial stability per rating
  #   w4..w6    difficulty
  #   w7..w14   slow-trace stability update
  #   w15..w22  fast-trace stability update
  #   w23..w33  forgetting curve (two power curves and their mixture weights)

  import Fsrs.Math, only: [clamp: 3]

  alias Fsrs.MemoryState

  @s_min Fsrs.Math.s_min()
  @s_max Fsrs.Math.s_max()
  @d_min Fsrs.Math.d_min()
  @d_max Fsrs.Math.d_max()

  @dr_min 0.0001
  @dr_max 0.9999
  @interval_newton_iters 7
  @bisection_iters 50
  @min_t 1.0 / 86_400.0
  @retention_tolerance 1.0e-6

  @slow_set 7
  @fast_set 15

  def init_difficulty(w, rating) do
    elem(w, 4) - :math.exp(elem(w, 5) * (rating - 1)) + 1.0
  end

  defp next_difficulty(w, d, rating, retention) do
    delta_d = -elem(w, 6) * (rating - 3.0)
    delta_d = if rating == 1, do: delta_d * (retention + 0.1), else: delta_d
    new_d = d + (10.0 - d) * delta_d / 9.0

    clamp(init_difficulty(w, 4) * 0.01 + new_d * 0.99, @d_min, @d_max)
  end

  # Stability update shared by both traces; `start` selects the parameter set.
  defp stability_for_set(w, last_s, last_d, retrievability, rating, start) do
    hard_penalty = if rating == 2, do: elem(w, start + 6), else: 1.0
    easy_bonus = if rating == 4, do: elem(w, start + 7), else: 1.0

    new_s_fail =
      elem(w, start + 3) *
        (:math.pow(last_s + 1.0, elem(w, start + 4)) - 1.0) *
        :math.exp((1.0 - retrievability) * elem(w, start + 5))

    pls = min(last_s, new_s_fail)

    sinc =
      :math.exp(elem(w, start) - 1.5) *
        (11.0 - last_d) *
        :math.pow(last_s, -elem(w, start + 1)) *
        (:math.exp((1.0 - retrievability) * elem(w, start + 2)) - 1.0) *
        hard_penalty *
        easy_bonus + 1.0

    new_s_success = max(pls, last_s * sinc)

    clamp(if(rating > 1, do: new_s_success, else: pls), @s_min, @s_max)
  end

  defp fast_curve(w, s_fast) do
    decay1 = -clamp(elem(w, 23) * :math.pow(s_fast, elem(w, 33) - 0.3), 0.01, 0.95)
    factor1 = :math.exp(min(:math.log(elem(w, 25)) / decay1, 60.0)) - 1.0
    {decay1, factor1}
  end

  defp fast_component_recall(w, t, s_fast) do
    t = max(t, 0.0)
    s_fast = clamp(s_fast, @s_min, @s_max)
    {decay1, factor1} = fast_curve(w, s_fast)
    :math.pow(1.0 + factor1 * (t / s_fast), decay1)
  end

  def next_state(w, %MemoryState{} = state, delta_t, rating) do
    delta_t = max(delta_t, 0.0)
    rating = clamp(rating, 1, 4)
    retrievability = forgetting_curve(w, delta_t, state)

    new_s_slow =
      stability_for_set(w, state.stability, state.difficulty, retrievability, rating, @slow_set)

    r_fast = fast_component_recall(w, delta_t, state.stability_fast)

    new_s_fast =
      stability_for_set(w, state.stability_fast, state.difficulty, r_fast, rating, @fast_set)

    new_s_fast = if rating == 1, do: min(new_s_fast, new_s_slow * 0.8), else: new_s_fast

    %MemoryState{
      stability: new_s_slow,
      difficulty: next_difficulty(w, state.difficulty, rating, retrievability),
      stability_fast: clamp(new_s_fast, @s_min, @s_max)
    }
  end

  def forgetting_curve(w, t, %MemoryState{} = state) do
    {retention, _derivative} = curve(w, t, state, nil)
    retention
  end

  # Retrievability and its derivative with respect to `t`.
  defp forgetting_curve_and_derivative(w, t, %MemoryState{} = state) do
    curve(w, t, state, 1.0e-9)
  end

  # `weight_floor` mirrors fsrs-rs: only the derivative variant floors the
  # weight sum.
  defp curve(w, t, state, weight_floor) do
    t = max(t, 0.0)
    s = max(state.stability, @s_min)
    s_fast = max(state.stability_fast, @s_min)
    d = clamp(state.difficulty, @d_min, @d_max)

    {decay1, factor1} = fast_curve(w, s_fast)
    b1 = 1.0 + factor1 * (t / s_fast)
    r1 = :math.pow(b1, decay1)
    dr1_dt = decay1 * :math.pow(b1, decay1 - 1.0) * factor1 / s_fast

    decay2 = -clamp(elem(w, 24), 0.01, 0.95)
    factor2 = :math.pow(elem(w, 26), 1.0 / decay2) - 1.0
    d_timescale = :math.exp((d - 5.0) * (elem(w, 32) - 0.3))
    b2 = 1.0 + factor2 * d_timescale * (t / s)
    r2 = :math.pow(b2, decay2)
    dr2_dt = decay2 * :math.pow(b2, decay2 - 1.0) * factor2 * d_timescale / s

    weight1 = elem(w, 27) * :math.pow(s_fast, -elem(w, 29))

    weight2 =
      elem(w, 28) * :math.pow(s, elem(w, 30)) * :math.exp((d - 5.0) * (elem(w, 31) - 0.5))

    weight_sum =
      if weight_floor, do: max(weight1 + weight2, weight_floor), else: weight1 + weight2

    retention = (weight1 * r1 + weight2 * r2) / weight_sum
    derivative = (weight1 * dr1_dt + weight2 * dr2_dt) / weight_sum

    {retention * (1.0 - 2.0e-5) + 1.0e-5, derivative * (1.0 - 2.0e-5)}
  end

  @doc false
  # Interval (days) at which the state's retrievability reaches
  # `desired_retention`: Newton iterations in log-time, bisection fallback.
  def next_interval(w, %MemoryState{} = state, desired_retention) do
    desired_retention = clamp(desired_retention, @dr_min, @dr_max)

    if desired_retention >= @dr_max do
      0.0
    else
      state = %MemoryState{
        stability: clamp(state.stability, @s_min, @s_max),
        difficulty: clamp(state.difficulty, @d_min, @d_max),
        stability_fast: clamp(state.stability_fast, @s_min, @s_max)
      }

      min_log_t = :math.log(@min_t)
      max_log_t = :math.log(@s_max)
      log_t = :math.log(max(max(state.stability, state.stability_fast), @min_t))

      log_t =
        Enum.reduce(1..@interval_newton_iters, log_t, fn _, log_t ->
          log_t = clamp(log_t, min_log_t, max_log_t)
          t = clamp(:math.exp(log_t), @min_t, @s_max)
          {retrievability, derivative} = forgetting_curve_and_derivative(w, t, state)
          df_du = min(derivative * t, -1.0e-12)
          step = clamp((retrievability - desired_retention) / df_du, -4.0, 4.0)
          log_t - step
        end)

      interval = clamp(:math.exp(log_t), 0.0, @s_max)
      retrievability = forgetting_curve(w, interval, state)

      if abs(retrievability - desired_retention) <= 1.0e-3 do
        interval
      else
        next_interval_bisection(w, state, desired_retention)
      end
    end
  end

  defp next_interval_bisection(w, state, desired_retention) do
    high =
      widen(w, state, desired_retention, max(max(state.stability, state.stability_fast), 1.0))

    {low, high} =
      Enum.reduce(1..@bisection_iters, {0.0, high}, fn _, {low, high} ->
        mid = (low + high) * 0.5

        if forgetting_curve(w, mid, state) > desired_retention do
          {mid, high}
        else
          {low, mid}
        end
      end)

    clamp((low + high) * 0.5, 0.0, @s_max)
  end

  defp widen(w, state, desired_retention, high) do
    if forgetting_curve(w, high, state) > desired_retention and high < @s_max do
      widen(w, state, desired_retention, min(high * 2.0, @s_max))
    else
      high
    end
  end

  @doc false
  # Finds the neutral-shaped state (`S_fast = 0.8 * S`, `D = 5`) whose
  # retrievability at `interval` equals `sm2_retention`.
  def memory_state_from_sm2(w, interval, sm2_retention) do
    if sm2_retention >= 0.0 and sm2_retention < 1.0 do
      interval = clamp(max(interval, @s_min), @s_min, @s_max)

      state_at = fn log_stability ->
        stability = clamp(:math.exp(log_stability), @s_min, @s_max)

        %MemoryState{
          stability: stability,
          difficulty: 5.0,
          stability_fast: clamp(stability * 0.8, @s_min, @s_max)
        }
      end

      low = :math.log(@s_min)
      high = :math.log(@s_max)
      low_state = state_at.(low)
      high_state = state_at.(high)

      cond do
        sm2_retention <= forgetting_curve(w, interval, low_state) ->
          {:ok, low_state}

        sm2_retention >= forgetting_curve(w, interval, high_state) ->
          {:ok, high_state}

        true ->
          {:ok, sm2_bisect(w, interval, sm2_retention, state_at, low, high, @bisection_iters)}
      end
    else
      {:error, :invalid_input}
    end
  end

  defp sm2_bisect(_w, _interval, _target, state_at, low, high, 0) do
    state_at.((low + high) * 0.5)
  end

  defp sm2_bisect(w, interval, target, state_at, low, high, iters) do
    mid = (low + high) * 0.5
    state = state_at.(mid)
    retention = forgetting_curve(w, interval, state)

    cond do
      abs(retention - target) <= @retention_tolerance -> state
      retention < target -> sm2_bisect(w, interval, target, state_at, mid, high, iters - 1)
      true -> sm2_bisect(w, interval, target, state_at, low, mid, iters - 1)
    end
  end
end
