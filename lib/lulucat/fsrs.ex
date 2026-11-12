defmodule Fsrs do
  @moduledoc """
  FSRS for Elixir: a port of the inference API of
  [`fsrs-rs`](https://github.com/open-spaced-repetition/fsrs-rs) `v7.0.0`.

  A model is created from a parameter list with `new/1`. The number of
  parameters selects the algorithm:

  | Parameters | Model |
  |---|---|
  | none, or 34 | FSRS-7 |
  | 21 | FSRS-6 |
  | 19 | FSRS-5 (expanded to 21) |
  | 17 | FSRS-4.5 (expanded to 21) |

  The model works on `Fsrs.MemoryState` values. `next_states/4` returns the new
  memory state and interval for each of the four ratings; the application keeps
  the state it chose, plus its own due dates, learning steps and fuzzing.

  Functions that return a `Result` in Rust return `{:ok, value}` or
  `{:error, reason}` here, where `reason` is `:invalid_parameters` or
  `:invalid_input`.

  Not ported: the optimizer (`compute_parameters`), evaluation, simulation and
  cost-ADR parts of fsrs-rs.

  中文说明：`fsrs_ex` 是 `fsrs-rs v7.0.0` 推理接口的 Elixir 移植。参数个数决定
  模型版本（不传或 34 个为 FSRS-7，21 个为 FSRS-6）。到期时间、学习步骤、
  间隔模糊等调度层逻辑由调用方自己处理。优化器、评估和模拟没有移植。

  ## Example

      iex> fsrs = Fsrs.default()
      iex> {:ok, next_states} = Fsrs.next_states(fsrs, nil, 0.9, 0)
      iex> next_states.good.memory.stability
      3.9221
      iex> Float.round(next_states.good.interval, 2)
      4.78
  """

  import Fsrs.Math, only: [clamp: 3]

  alias Fsrs.Item
  alias Fsrs.ItemState
  alias Fsrs.MemoryState
  alias Fsrs.ModelV6
  alias Fsrs.ModelV7
  alias Fsrs.NextStates
  alias Fsrs.Parameters
  alias Fsrs.Rating
  alias Fsrs.Review

  @s_min Fsrs.Math.s_min()
  @s_max Fsrs.Math.s_max()
  @d_min Fsrs.Math.d_min()
  @d_max Fsrs.Math.d_max()

  @enforce_keys [:parameters, :version]
  defstruct [:parameters, :version]

  @typedoc """
  An FSRS model. `parameters` holds the filled and clipped parameters as a tuple.
  """
  @type t :: %__MODULE__{parameters: tuple(), version: version()}

  @type version :: :fsrs6 | :fsrs7
  @type parameters :: [number()] | tuple()
  @type error :: :invalid_parameters | :invalid_input

  # ----------------------------------------------------------------------
  # Constants
  # ----------------------------------------------------------------------

  @doc """
  The default FSRS-7 parameters (34 values).

  中文说明：FSRS-7 的默认 34 个参数。
  """
  @spec default_parameters() :: [float()]
  def default_parameters, do: Parameters.default_parameters()

  @doc """
  The default FSRS-6 parameters (21 values).

  中文说明：FSRS-6 的默认 21 个参数。
  """
  @spec fsrs6_default_parameters() :: [float()]
  def fsrs6_default_parameters, do: Parameters.fsrs6_default_parameters()

  @doc "The forgetting-curve decay used by FSRS-5 and earlier (`0.5`)."
  @spec fsrs5_default_decay() :: float()
  def fsrs5_default_decay, do: Parameters.fsrs5_default_decay()

  @doc "The default forgetting-curve decay of FSRS-6 (`0.1542`)."
  @spec fsrs6_default_decay() :: float()
  def fsrs6_default_decay, do: Parameters.fsrs6_default_decay()

  # ----------------------------------------------------------------------
  # Construction
  # ----------------------------------------------------------------------

  @doc """
  Creates a model. Empty parameters select the FSRS-7 defaults.

  Parameters are clipped to their valid ranges rather than rejected. A wrong
  parameter count or a non-numeric value returns `{:error, :invalid_parameters}`.

  中文说明：创建模型。超出范围的参数会被截断到合法区间，不会报错；
  参数个数不对或含非数字时返回 `{:error, :invalid_parameters}`。

  ## Examples

      iex> {:ok, fsrs} = Fsrs.new()
      iex> Fsrs.version(fsrs)
      :fsrs7

      iex> {:ok, fsrs} = Fsrs.new(Fsrs.fsrs6_default_parameters())
      iex> Fsrs.version(fsrs)
      :fsrs6

      iex> Fsrs.new([1.0, 2.0])
      {:error, :invalid_parameters}
  """
  @spec new(parameters()) :: {:ok, t()} | {:error, :invalid_parameters}
  def new(parameters \\ []) do
    with {:ok, parameters} <- Parameters.check_and_fill(parameters) do
      parameters = Parameters.clip(parameters)

      {:ok,
       %__MODULE__{
         parameters: List.to_tuple(parameters),
         version: Parameters.version_from_param_count(length(parameters))
       }}
    end
  end

  @doc """
  Like `new/1`, but raises `ArgumentError` on invalid parameters.
  """
  @spec new!(parameters()) :: t()
  def new!(parameters \\ []) do
    case new(parameters) do
      {:ok, fsrs} -> fsrs
      {:error, :invalid_parameters} -> raise ArgumentError, "invalid FSRS parameters"
    end
  end

  @doc """
  The default model: FSRS-7 with the default parameters.
  """
  @spec default() :: t()
  def default, do: new!([])

  @doc """
  Returns the algorithm version used by a model.
  """
  @spec version(t()) :: version()
  def version(%__MODULE__{version: version}), do: version

  @doc """
  Validates parameters and fills empty input with the FSRS-7 defaults.

  Legacy 17- and 19-parameter inputs are expanded to 21 FSRS-6 parameters.
  The result is not clipped.

  中文说明：校验参数；空输入填充为 FSRS-7 默认值，17/19 个的旧版参数扩展为
  21 个。返回值未做截断。

  ## Examples

      iex> {:ok, parameters} = Fsrs.check_and_fill_parameters([])
      iex> parameters == Fsrs.default_parameters()
      true
  """
  @spec check_and_fill_parameters(parameters()) ::
          {:ok, [float()]} | {:error, :invalid_parameters}
  def check_and_fill_parameters(parameters), do: Parameters.check_and_fill(parameters)

  # ----------------------------------------------------------------------
  # Memory state
  # ----------------------------------------------------------------------

  @doc """
  Calculates the memory state for a card's review history.

  For a truncated history, `starting_state` can be set to the result of
  `memory_state_from_sm2/4` for the first review, which should then not be
  included in the item. Without it the card starts as new.

  中文说明：根据复习历史计算当前记忆状态。历史不完整时可用
  `memory_state_from_sm2/4` 的结果作为起始状态。

  ## Examples

      iex> item = Fsrs.Item.new([{:good, 0}, {:good, 4}, {:hard, 11.5}])
      iex> {:ok, state} = Fsrs.memory_state(Fsrs.default(), item)
      iex> state.stability > 3.9221
      true
  """
  @spec memory_state(t(), Item.t(), MemoryState.t() | nil) ::
          {:ok, MemoryState.t()} | {:error, :invalid_input}
  def memory_state(%__MODULE__{} = fsrs, %Item{} = item, starting_state \\ nil) do
    guard_input(fn -> forward_reviews(fsrs, item.reviews, starting_state) end)
  end

  @doc """
  `memory_state/3` for several items. `starting_states` must have one entry
  (a state or `nil`) per item.
  """
  @spec memory_state_batch(t(), [Item.t()], [MemoryState.t() | nil]) ::
          {:ok, [MemoryState.t()]} | {:error, :invalid_input}
  def memory_state_batch(%__MODULE__{} = fsrs, items, starting_states)
      when is_list(items) and is_list(starting_states) do
    if length(items) == length(starting_states) do
      items
      |> Enum.zip(starting_states)
      |> collect(fn {item, starting_state} -> memory_state(fsrs, item, starting_state) end)
    else
      {:error, :invalid_input}
    end
  end

  @doc """
  The memory state after each review of an item.

  When `starting_state` is given it is the first element of the result.

  中文说明：返回每次复习之后的记忆状态序列。
  """
  @spec historical_memory_states(t(), Item.t(), MemoryState.t() | nil) ::
          {:ok, [MemoryState.t()]} | {:error, :invalid_input}
  def historical_memory_states(%__MODULE__{} = fsrs, %Item{} = item, starting_state \\ nil) do
    guard_input(fn ->
      {states, _state} =
        item.reviews
        |> Enum.with_index()
        |> Enum.map_reduce(starting_state || zero_state(), fn {review, index}, state ->
          state = step(fsrs, review.delta_t, review.rating, state, index)
          {state, state}
        end)

      if starting_state, do: [starting_state | states], else: states
    end)
  end

  @doc """
  `historical_memory_states/3` for several items.
  """
  @spec historical_memory_state_batch(t(), [Item.t()], [MemoryState.t() | nil] | nil) ::
          {:ok, [[MemoryState.t()]]} | {:error, :invalid_input}
  def historical_memory_state_batch(%__MODULE__{} = fsrs, items, starting_states \\ nil)
      when is_list(items) do
    starting_states = starting_states || Enum.map(items, fn _ -> nil end)

    cond do
      items == [] ->
        {:ok, []}

      length(items) != length(starting_states) ->
        {:error, :invalid_input}

      true ->
        items
        |> Enum.zip(starting_states)
        |> collect(fn {item, starting_state} ->
          historical_memory_states(fsrs, item, starting_state)
        end)
    end
  end

  @doc """
  Approximates a memory state from SM-2 values, for cards with an incomplete
  review history.

  For FSRS-7 the returned state reaches `sm2_retention` at `interval` (when
  representable within the stability bounds) and `ease_factor` is ignored. For
  FSRS-6 the ease factor is used to estimate difficulty.

  中文说明：由 SM-2 的易度因子和间隔近似出记忆状态，用于复习历史不完整的卡片。
  FSRS-7 下忽略 `ease_factor`。

  ## Examples

      iex> fsrs = Fsrs.default()
      iex> {:ok, state} = Fsrs.memory_state_from_sm2(fsrs, 2.5, 30.0, 0.9)
      iex> Float.round(Fsrs.interval_at_retrievability(fsrs, state, 0.9), 1)
      30.0

      iex> Fsrs.memory_state_from_sm2(Fsrs.default(), 2.5, 30.0, 1.0)
      {:error, :invalid_input}
  """
  @spec memory_state_from_sm2(t(), number(), number(), number()) ::
          {:ok, MemoryState.t()} | {:error, :invalid_input}
  def memory_state_from_sm2(%__MODULE__{} = fsrs, ease_factor, interval, sm2_retention)
      when is_number(ease_factor) and is_number(interval) and is_number(sm2_retention) do
    case fsrs.version do
      :fsrs6 ->
        ModelV6.memory_state_from_sm2(fsrs.parameters, ease_factor, interval, sm2_retention)

      :fsrs7 ->
        ModelV7.memory_state_from_sm2(fsrs.parameters, interval, sm2_retention)
    end
  end

  # ----------------------------------------------------------------------
  # Retrievability and intervals
  # ----------------------------------------------------------------------

  @doc """
  Calculates current retrievability (probability of recall).

  Two forms, as in fsrs-rs:

  - `current_retrievability(fsrs, state, days_elapsed)` uses the model's
    forgetting curve. FSRS-6 rounds `days_elapsed` to whole days; FSRS-7 uses
    it as is.
  - `current_retrievability(state, days_elapsed, decay)` is the stand-alone
    single-curve formula of FSRS-6 and earlier, with an explicit `decay`.

  中文说明：计算当前可提取率。第一种形式使用模型自身的遗忘曲线；第二种是
  FSRS-6 及更早版本的单曲线公式，需显式传入 `decay`。

  ## Examples

      iex> fsrs = Fsrs.default()
      iex> state = %Fsrs.MemoryState{stability: 10.0, difficulty: 5.0, stability_fast: 8.0}
      iex> r = Fsrs.current_retrievability(fsrs, state, 3.5)
      iex> r > 0.9 and r < 1.0
      true

      iex> state = %Fsrs.MemoryState{stability: 10.0, difficulty: 5.0, stability_fast: 10.0}
      iex> Float.round(Fsrs.current_retrievability(state, 10.0, Fsrs.fsrs6_default_decay()), 6)
      0.9
  """
  @spec current_retrievability(t(), MemoryState.t(), number()) :: float()
  @spec current_retrievability(MemoryState.t(), number(), number()) :: float()
  def current_retrievability(%__MODULE__{} = fsrs, %MemoryState{} = state, days_elapsed)
      when is_number(days_elapsed) do
    forgetting_curve(fsrs, max(days_elapsed, 0.0), state)
  end

  def current_retrievability(%MemoryState{} = state, days_elapsed, decay)
      when is_number(days_elapsed) and is_number(decay) do
    factor = :math.pow(0.9, 1.0 / -decay) - 1.0
    :math.pow(days_elapsed / state.stability * factor + 1.0, -decay)
  end

  @doc """
  The interval in days at which the state's retrievability reaches
  `desired_retention`.

  中文说明：记忆状态的可提取率降到 `desired_retention` 时的间隔（天）。
  """
  @spec next_interval_for_state(t(), MemoryState.t(), number()) :: float()
  def next_interval_for_state(%__MODULE__{} = fsrs, %MemoryState{} = state, desired_retention)
      when is_number(desired_retention) do
    case fsrs.version do
      :fsrs6 -> ModelV6.next_interval(fsrs.parameters, state.stability, desired_retention)
      :fsrs7 -> ModelV7.next_interval(fsrs.parameters, state, desired_retention)
    end
  end

  @doc """
  Like `next_interval_for_state/3`, with `target` clamped to `0.0001..0.9999`.
  """
  @spec interval_at_retrievability(t(), MemoryState.t(), number()) :: float()
  def interval_at_retrievability(%__MODULE__{} = fsrs, %MemoryState{} = state, target)
      when is_number(target) do
    next_interval_for_state(fsrs, state, clamp(target, 0.0001, 0.9999))
  end

  @doc """
  The S90 interval of a state: the number of days until retrievability reaches
  90%.

  For FSRS-6 this equals `state.stability`. For FSRS-7 it is solved
  numerically from the forgetting curve.

  中文说明：可提取率降到 90% 所需的天数。FSRS-6 下约等于 `stability`，
  FSRS-7 下由遗忘曲线数值求解。

  ## Examples

      iex> fsrs = Fsrs.default()
      iex> state = %Fsrs.MemoryState{stability: 10.0, difficulty: 5.0, stability_fast: 8.0}
      iex> s90 = Fsrs.s90(fsrs, state)
      iex> Float.round(Fsrs.current_retrievability(fsrs, state, s90), 3)
      0.9
  """
  @spec s90(t(), MemoryState.t()) :: float()
  def s90(%__MODULE__{} = fsrs, %MemoryState{} = state) do
    interval_at_retrievability(fsrs, state, 0.9)
  end

  @doc """
  Calculates the next interval from a bare stability value, for rescheduling.

  `stability` should be given except for a new card (`nil`), in which case the
  initial stability for `rating` is used. `rating` is otherwise ignored. The
  state is treated as neutral (`difficulty` 5, fast trace equal to
  `stability`); prefer `next_interval_for_state/3` when the full state is known.

  中文说明：仅凭稳定性计算下次间隔，用于重排。已知完整记忆状态时应改用
  `next_interval_for_state/3`。
  """
  @spec next_interval(t(), number() | nil, number(), Rating.t() | non_neg_integer()) :: float()
  def next_interval(%__MODULE__{} = fsrs, stability, desired_retention, rating)
      when (is_number(stability) or is_nil(stability)) and is_number(desired_retention) do
    stability = stability || init_stability(fsrs, Rating.to_int(rating))

    next_interval_for_state(
      fsrs,
      %MemoryState{stability: stability, difficulty: 5.0, stability_fast: stability},
      desired_retention
    )
  end

  # ----------------------------------------------------------------------
  # Scheduling
  # ----------------------------------------------------------------------

  @doc """
  The memory state and interval for each answer button.

  `current_memory_state` is `nil` for a new card. `days_elapsed` is the whole
  number of days since the last review; use `next_states_with_elapsed_days/4`
  for fractional days.

  Intervals are fractional days and are not rounded, floored to a minimum, or
  capped at a maximum interval — that is up to the caller.

  中文说明：返回四个评分各自对应的新记忆状态和间隔。新卡传 `nil`。间隔是
  未取整的小数天，取整、最小间隔、最大间隔由调用方决定。

  ## Examples

      iex> {:ok, next_states} = Fsrs.next_states(Fsrs.default(), nil, 0.9, 0)
      iex> next_states.easy.memory.stability
      11.7841
      iex> next_states.easy.memory.difficulty
      1.0
      iex> Float.round(next_states.easy.interval, 1)
      53.9
  """
  @spec next_states(t(), MemoryState.t() | nil, number(), non_neg_integer()) ::
          {:ok, NextStates.t()} | {:error, :invalid_input}
  def next_states(%__MODULE__{} = fsrs, current_memory_state, desired_retention, days_elapsed)
      when is_integer(days_elapsed) and days_elapsed >= 0 do
    next_states_with_elapsed_days(fsrs, current_memory_state, desired_retention, days_elapsed)
  end

  @doc """
  Like `next_states/4`, but accepts fractional elapsed days.

  FSRS-7 uses the fractional value as is, so same-day reviews are handled by
  the same formulas as later ones. FSRS-6 rounds it to whole days.

  中文说明：与 `next_states/4` 相同，但接受小数天。FSRS-7 直接使用小数值；
  FSRS-6 会四舍五入到整天。
  """
  @spec next_states_with_elapsed_days(t(), MemoryState.t() | nil, number(), number()) ::
          {:ok, NextStates.t()} | {:error, :invalid_input}
  def next_states_with_elapsed_days(
        %__MODULE__{} = fsrs,
        current_memory_state,
        desired_retention,
        days_elapsed
      )
      when (is_struct(current_memory_state, MemoryState) or is_nil(current_memory_state)) and
             is_number(desired_retention) and is_number(days_elapsed) do
    {state, nth} =
      if current_memory_state, do: {current_memory_state, 1}, else: {zero_state(), 0}

    guard_input(fn ->
      [again, hard, good, easy] =
        for rating <- 1..4 do
          memory = step(fsrs, days_elapsed, rating, state, nth)

          %ItemState{
            memory: memory,
            interval: next_interval_for_state(fsrs, memory, desired_retention)
          }
        end

      %NextStates{again: again, hard: hard, good: good, easy: easy}
    end)
  end

  # ----------------------------------------------------------------------
  # Internals (mirroring `model.rs`)
  # ----------------------------------------------------------------------

  defp zero_state, do: %MemoryState{stability: 0.0, difficulty: 0.0, stability_fast: 0.0}

  defp forgetting_curve(%__MODULE__{version: :fsrs6, parameters: w}, t, state) do
    ModelV6.forgetting_curve(w, t, state.stability)
  end

  defp forgetting_curve(%__MODULE__{version: :fsrs7, parameters: w}, t, state) do
    ModelV7.forgetting_curve(w, t, state)
  end

  defp init_stability(%__MODULE__{parameters: w}, rating) do
    elem(w, rating |> Kernel.-(1) |> clamp(0, 3))
  end

  defp init_difficulty(%__MODULE__{version: :fsrs6, parameters: w}, rating) do
    ModelV6.init_difficulty(w, rating)
  end

  defp init_difficulty(%__MODULE__{version: :fsrs7, parameters: w}, rating) do
    ModelV7.init_difficulty(w, rating)
  end

  defp init_state(fsrs, rating) do
    rating = clamp(rating, 1, 4)
    stability = clamp(init_stability(fsrs, rating), @s_min, @s_max)

    %MemoryState{
      stability: stability,
      difficulty: clamp(init_difficulty(fsrs, rating), @d_min, @d_max),
      stability_fast:
        if(fsrs.version == :fsrs7, do: clamp(stability * 0.8, @s_min, @s_max), else: stability)
    }
  end

  # One review. `nth` is the index of the review in its history; a zero
  # stability at index 0 marks a new card. Rating 0 leaves the state unchanged.
  defp step(fsrs, delta_t, rating, %MemoryState{} = state, nth)
       when is_integer(rating) and rating >= 0 and is_number(delta_t) do
    cond do
      rating == 0 ->
        %MemoryState{
          stability: clamp(state.stability, @s_min, @s_max),
          difficulty: clamp(state.difficulty, @d_min, @d_max),
          stability_fast: clamp(state.stability_fast, @s_min, @s_max)
        }

      nth == 0 and state.stability == 0 ->
        init_state(fsrs, rating)

      true ->
        last = %MemoryState{
          stability: clamp(state.stability, @s_min, @s_max),
          difficulty: clamp(state.difficulty, @d_min, @d_max),
          stability_fast: clamp(state.stability_fast, @s_min, @s_max)
        }

        case fsrs.version do
          :fsrs6 -> ModelV6.next_state(fsrs.parameters, last, delta_t, rating)
          :fsrs7 -> ModelV7.next_state(fsrs.parameters, last, delta_t, rating)
        end
    end
  end

  defp init_state_from_first_review(_fsrs, %Review{rating: 0}) do
    %MemoryState{stability: @s_min, difficulty: @d_min, stability_fast: @s_min}
  end

  defp init_state_from_first_review(fsrs, %Review{rating: rating}), do: init_state(fsrs, rating)

  defp forward_reviews(fsrs, reviews, %MemoryState{} = starting_state) do
    replay(fsrs, Enum.with_index(reviews), starting_state)
  end

  defp forward_reviews(_fsrs, [], nil), do: zero_state()

  defp forward_reviews(fsrs, [first | rest], nil) do
    replay(fsrs, Enum.with_index(rest, 1), init_state_from_first_review(fsrs, first))
  end

  defp replay(fsrs, indexed_reviews, state) do
    Enum.reduce(indexed_reviews, state, fn {%Review{} = review, index}, state ->
      step(fsrs, review.delta_t, review.rating, state, index)
    end)
  end

  # fsrs-rs reports non-finite results as `InvalidInput`. The BEAM has no
  # NaN or infinity and raises `ArithmeticError` instead.
  defp guard_input(fun) do
    {:ok, fun.()}
  rescue
    ArithmeticError -> {:error, :invalid_input}
  end

  defp collect(enumerable, fun) do
    enumerable
    |> Enum.reduce_while({:ok, []}, fn element, {:ok, acc} ->
      case fun.(element) do
        {:ok, value} -> {:cont, {:ok, [value | acc]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, values} -> {:ok, Enum.reverse(values)}
      error -> error
    end
  end
end
