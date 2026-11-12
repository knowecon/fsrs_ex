defmodule FsrsTest do
  use ExUnit.Case, async: true

  doctest Fsrs
  doctest Fsrs.Item
  doctest Fsrs.NextStates
  doctest Fsrs.Rating
  doctest Fsrs.Review

  alias Fsrs.MemoryState

  describe "new/1" do
    test "selects the model from the parameter count" do
      assert Fsrs.version(Fsrs.default()) == :fsrs7
      assert Fsrs.version(Fsrs.new!(Fsrs.default_parameters())) == :fsrs7
      assert Fsrs.version(Fsrs.new!(Fsrs.fsrs6_default_parameters())) == :fsrs6
      assert Fsrs.version(Fsrs.new!(Enum.take(Fsrs.fsrs6_default_parameters(), 19))) == :fsrs6
      assert Fsrs.version(Fsrs.new!(Enum.take(Fsrs.fsrs6_default_parameters(), 17))) == :fsrs6
    end

    test "accepts tuples and integers" do
      parameters = Fsrs.default_parameters() |> List.replace_at(14, 1) |> List.to_tuple()
      assert Fsrs.new!(parameters) == Fsrs.default()
    end

    test "rejects wrong counts and non-numeric values" do
      for count <- Enum.to_list(1..35) -- [17, 19, 21, 34] do
        assert Fsrs.new(List.duplicate(1.0, count)) == {:error, :invalid_parameters}
      end

      assert Fsrs.new(List.replace_at(Fsrs.default_parameters(), 0, "1.0")) ==
               {:error, :invalid_parameters}

      assert Fsrs.new(:default) == {:error, :invalid_parameters}
      assert_raise ArgumentError, fn -> Fsrs.new!([1.0]) end
    end

    test "clips out-of-range parameters instead of rejecting them" do
      parameters = List.replace_at(Fsrs.default_parameters(), 4, 99.0)
      assert {:ok, fsrs} = Fsrs.new(parameters)
      assert elem(fsrs.parameters, 4) == 10.0

      # FSRS-7 keeps initial stabilities ordered and w26 >= w25.
      parameters =
        Fsrs.default_parameters()
        |> List.replace_at(2, 1.0)
        |> List.replace_at(25, 0.7)
        |> List.replace_at(26, 0.6)

      assert {:ok, fsrs} = Fsrs.new(parameters)
      assert elem(fsrs.parameters, 2) == elem(fsrs.parameters, 1)
      assert elem(fsrs.parameters, 26) == 0.7
    end
  end

  describe "FSRS-7" do
    setup do
      %{fsrs: Fsrs.default()}
    end

    test "new card states follow the initial parameters", %{fsrs: fsrs} do
      {:ok, next_states} = Fsrs.next_states(fsrs, nil, 0.9, 0)

      assert next_states.again.memory.stability == 0.1104
      assert next_states.good.memory.stability == 3.9221
      assert_in_delta next_states.good.memory.stability_fast, 3.9221 * 0.8, 1.0e-12
      assert next_states.easy.memory.difficulty == 1.0

      intervals =
        Enum.map([:again, :hard, :good, :easy], &Fsrs.NextStates.fetch!(next_states, &1).interval)

      assert intervals == Enum.sort(intervals)
    end

    test "interval solves the forgetting curve for the desired retention", %{fsrs: fsrs} do
      state = %MemoryState{stability: 12.0, difficulty: 6.5, stability_fast: 4.0}

      for retention <- [0.7, 0.8, 0.9, 0.95, 0.99] do
        interval = Fsrs.next_interval_for_state(fsrs, state, retention)
        assert_in_delta Fsrs.current_retrievability(fsrs, state, interval), retention, 1.0e-3
      end
    end

    test "stability is not the 90% interval; s90 is", %{fsrs: fsrs} do
      state = %MemoryState{stability: 10.0, difficulty: 5.0, stability_fast: 8.0}
      s90 = Fsrs.s90(fsrs, state)

      assert abs(s90 - state.stability) > 0.1
      assert_in_delta Fsrs.current_retrievability(fsrs, state, s90), 0.9, 1.0e-3
    end

    test "retrievability decreases with elapsed time and uses fractional days", %{fsrs: fsrs} do
      state = %MemoryState{stability: 10.0, difficulty: 5.0, stability_fast: 8.0}

      values =
        Enum.map(
          [0.0, 0.01, 0.5, 1.0, 10.0, 100.0],
          &Fsrs.current_retrievability(fsrs, state, &1)
        )

      assert values == Enum.sort(values, :desc)
      assert Enum.uniq(values) == values
      assert Fsrs.current_retrievability(fsrs, state, -5) == hd(values)
    end

    test "same-day reviews use the fractional elapsed time", %{fsrs: fsrs} do
      state = %MemoryState{stability: 3.9221, difficulty: 3.53, stability_fast: 3.13768}

      {:ok, after_minute} = Fsrs.next_states_with_elapsed_days(fsrs, state, 0.9, 1 / 1440)
      {:ok, after_half_day} = Fsrs.next_states_with_elapsed_days(fsrs, state, 0.9, 0.5)

      assert after_minute.good.memory.stability < after_half_day.good.memory.stability
    end

    test "a lapse lowers stability and raises difficulty", %{fsrs: fsrs} do
      state = %MemoryState{stability: 50.0, difficulty: 5.0, stability_fast: 40.0}
      {:ok, next_states} = Fsrs.next_states(fsrs, state, 0.9, 50)

      assert next_states.again.memory.stability < state.stability
      assert next_states.again.memory.stability_fast <= next_states.again.memory.stability * 0.8
      assert next_states.again.memory.difficulty > state.difficulty
      assert next_states.good.memory.stability > state.stability
    end

    test "memory_state replays a history like chained next_states", %{fsrs: fsrs} do
      reviews = [{3, 0}, {3, 4.25}, {1, 12.0}, {3, 0.01}, {4, 3.0}]

      chained =
        Enum.reduce(reviews, nil, fn {rating, delta_t}, state ->
          {:ok, next_states} = Fsrs.next_states_with_elapsed_days(fsrs, state, 0.9, delta_t)
          Fsrs.NextStates.fetch!(next_states, rating).memory
        end)

      assert {:ok, ^chained} = Fsrs.memory_state(fsrs, Fsrs.Item.new(reviews))

      {:ok, history} = Fsrs.historical_memory_states(fsrs, Fsrs.Item.new(reviews))
      assert length(history) == length(reviews)
      assert List.last(history) == chained
    end

    test "memory_state_from_sm2 preserves the interval at the given retention", %{fsrs: fsrs} do
      for retention <- [0.8, 0.9, 0.95], interval <- [1.0, 30.0, 100.0] do
        {:ok, state} = Fsrs.memory_state_from_sm2(fsrs, 2.5, interval, retention)

        assert state.difficulty == 5.0
        assert_in_delta state.stability_fast / state.stability, 0.8, 1.0e-9
        assert_in_delta Fsrs.interval_at_retrievability(fsrs, state, retention), interval, 0.01
      end
    end
  end

  describe "FSRS-6" do
    setup do
      %{fsrs: Fsrs.new!(Fsrs.fsrs6_default_parameters())}
    end

    test "keeps the fast trace equal to stability", %{fsrs: fsrs} do
      {:ok, next_states} = Fsrs.next_states(fsrs, nil, 0.9, 0)
      assert next_states.good.memory.stability == 2.3065
      assert next_states.good.memory.stability_fast == 2.3065

      {:ok, next_states} = Fsrs.next_states(fsrs, next_states.good.memory, 0.9, 2)
      assert next_states.good.memory.stability_fast == next_states.good.memory.stability
    end

    test "s90 equals stability", %{fsrs: fsrs} do
      state = %MemoryState{stability: 12.345, difficulty: 5.0, stability_fast: 12.345}
      assert_in_delta Fsrs.s90(fsrs, state), 12.345, 1.0e-9
    end

    test "rounds elapsed time to whole days", %{fsrs: fsrs} do
      state = %MemoryState{stability: 10.0, difficulty: 5.0, stability_fast: 10.0}

      assert Fsrs.current_retrievability(fsrs, state, 0.49) ==
               Fsrs.current_retrievability(fsrs, state, 0)

      assert Fsrs.current_retrievability(fsrs, state, 0.51) ==
               Fsrs.current_retrievability(fsrs, state, 1)
    end

    test "a same-day Hard review does not lower stability", %{fsrs: fsrs} do
      {:ok, new_card} = Fsrs.next_states(fsrs, nil, 0.9, 0)
      state = new_card.good.memory
      {:ok, same_day} = Fsrs.next_states(fsrs, state, 0.9, 0)

      assert same_day.hard.memory.stability == state.stability
      assert same_day.again.memory.stability < state.stability
    end
  end

  describe "input handling" do
    test "batch functions check lengths" do
      fsrs = Fsrs.default()
      item = Fsrs.Item.new([{3, 0}, {3, 2}])

      assert {:ok, [state, state]} = Fsrs.memory_state_batch(fsrs, [item, item], [nil, nil])
      assert Fsrs.memory_state_batch(fsrs, [item], []) == {:error, :invalid_input}
      assert Fsrs.memory_state_batch(fsrs, [], []) == {:ok, []}

      assert {:ok, [[_, _], [_, _]]} = Fsrs.historical_memory_state_batch(fsrs, [item, item])

      assert Fsrs.historical_memory_state_batch(fsrs, [item], [nil, nil]) ==
               {:error, :invalid_input}
    end

    test "an empty history yields the zero state" do
      assert Fsrs.memory_state(Fsrs.default(), %Fsrs.Item{}) ==
               {:ok, %MemoryState{stability: 0.0, difficulty: 0.0, stability_fast: 0.0}}
    end

    test "next_states/4 takes whole days only" do
      assert_raise FunctionClauseError, fn -> Fsrs.next_states(Fsrs.default(), nil, 0.9, 0.5) end
      assert_raise FunctionClauseError, fn -> Fsrs.next_states(Fsrs.default(), nil, 0.9, -1) end
    end

    test "next_interval accepts rating atoms for new cards" do
      fsrs = Fsrs.default()

      assert Fsrs.next_interval(fsrs, nil, 0.9, :good) == Fsrs.next_interval(fsrs, nil, 0.9, 3)
      assert Fsrs.next_interval(fsrs, 7.0, 0.9, :again) == Fsrs.next_interval(fsrs, 7.0, 0.9, 4)
    end
  end
end
