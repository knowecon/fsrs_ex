defmodule Fsrs.RsParityTest do
  @moduledoc """
  Compares fsrs_ex against outputs recorded from the `fsrs` Rust crate.

  The fixture is produced by `test/fixtures/rust_fixture` (see
  `guides/PARITY_TESTING.md`).
  """

  use ExUnit.Case, async: true

  alias Fsrs.MemoryState

  @fixture_path Path.expand("fixtures/fsrs_rs_v7_0_0_fixture.json.gz", __DIR__)

  # fsrs-rs computes in 32-bit floats and fsrs_ex in 64-bit, so results are
  # compared with a relative tolerance. The largest observed difference is
  # about 2.4e-4, in subtractions that cancel in `f32`.
  @tolerance 5.0e-4

  setup_all do
    fixture = @fixture_path |> File.read!() |> :zlib.gunzip() |> JSON.decode!()

    models =
      for model <- fixture["models"] do
        {:ok, fsrs} = Fsrs.new(model["parameters"])
        {model, fsrs}
      end

    %{fixture: fixture, models: models}
  end

  test "package version tracks the fsrs-rs version of the fixture", %{fixture: fixture} do
    major_minor = fn version -> version |> String.split(".") |> Enum.take(2) end

    assert fixture["meta"]["fsrs_rs_version"] == "7.0.0"

    assert major_minor.(Mix.Project.config()[:version]) ==
             major_minor.(fixture["meta"]["fsrs_rs_version"])
  end

  test "default parameters and decay constants", %{fixture: fixture} do
    assert Fsrs.default_parameters() == fixture["default_parameters"]
    assert Fsrs.fsrs6_default_parameters() == fixture["fsrs6_default_parameters"]
    assert Fsrs.fsrs5_default_decay() == fixture["fsrs5_default_decay"]
    assert Fsrs.fsrs6_default_decay() == fixture["fsrs6_default_decay"]
  end

  test "default model is FSRS-7", %{fixture: fixture} do
    expected = fixture["default_model"]
    assert Atom.to_string(Fsrs.version(Fsrs.default())) == expected["version"]

    {:ok, next_states} = Fsrs.next_states(Fsrs.default(), nil, 0.9, 0)
    assert_next_states(next_states, expected["next_states"], "default")

    {:ok, fsrs} = Fsrs.new([])
    {:ok, next_states} = Fsrs.next_states(fsrs, nil, 0.9, 0)
    assert_next_states(next_states, expected["empty_parameters_next_states"], "empty")
  end

  test "check_and_fill_parameters and model version selection", %{fixture: fixture} do
    for entry <- fixture["check_and_fill_parameters"] do
      input = entry["input"]
      context = "#{length(input)} parameters"

      case entry["result"] do
        %{"ok" => expected} ->
          assert {:ok, actual} = Fsrs.check_and_fill_parameters(input), context
          assert length(actual) == length(expected), context
          Enum.zip(actual, expected) |> Enum.each(fn {a, e} -> assert_close(a, e, context) end)

        %{"error" => "InvalidParameters"} ->
          assert Fsrs.check_and_fill_parameters(input) == {:error, :invalid_parameters}, context
      end

      case entry["new"] do
        %{"ok" => version} ->
          assert {:ok, fsrs} = Fsrs.new(input), context
          assert Atom.to_string(Fsrs.version(fsrs)) == version, context

        %{"error" => "InvalidParameters"} ->
          assert Fsrs.new(input) == {:error, :invalid_parameters}, context
      end
    end
  end

  test "stand-alone current_retrievability with explicit decay", %{fixture: fixture} do
    for entry <- fixture["current_retrievability_with_decay"] do
      actual =
        Fsrs.current_retrievability(state(entry["state"]), entry["days_elapsed"], entry["decay"])

      assert_close(actual, entry["result"], inspect(entry))
    end
  end

  test "model versions", %{models: models} do
    for {model, fsrs} <- models do
      assert Atom.to_string(Fsrs.version(fsrs)) == model["version"], model["name"]
    end
  end

  test "current_retrievability", %{models: models} do
    for {model, fsrs} <- models, entry <- model["current_retrievability"] do
      actual = Fsrs.current_retrievability(fsrs, state(entry["state"]), entry["days_elapsed"])
      assert_close(actual, entry["result"], context(model, entry))
    end
  end

  test "interval_at_retrievability and next_interval_for_state", %{models: models} do
    for {model, fsrs} <- models, entry <- model["intervals"] do
      state = state(entry["state"])
      context = context(model, entry)

      assert_close(
        Fsrs.interval_at_retrievability(fsrs, state, entry["target"]),
        entry["interval_at_retrievability"],
        context
      )

      assert_close(
        Fsrs.next_interval_for_state(fsrs, state, entry["target"]),
        entry["next_interval_for_state"],
        context
      )
    end
  end

  test "s90", %{models: models} do
    for {model, fsrs} <- models, entry <- model["s90"] do
      assert_close(Fsrs.s90(fsrs, state(entry["state"])), entry["result"], context(model, entry))
    end
  end

  test "next_interval", %{models: models} do
    for {model, fsrs} <- models, entry <- model["next_interval"] do
      actual =
        Fsrs.next_interval(
          fsrs,
          entry["stability"],
          entry["desired_retention"],
          entry["rating"]
        )

      assert_close(actual, entry["result"], context(model, entry))
    end
  end

  test "next_states and next_states_with_elapsed_days", %{models: models} do
    for {model, fsrs} <- models, entry <- model["next_states"] do
      fun =
        if entry["integer_days"],
          do: &Fsrs.next_states/4,
          else: &Fsrs.next_states_with_elapsed_days/4

      assert {:ok, next_states} =
               fun.(
                 fsrs,
                 state(entry["state"]),
                 entry["desired_retention"],
                 entry["days_elapsed"]
               )

      assert_next_states(next_states, entry["result"]["ok"], context(model, entry))
    end
  end

  test "memory_state and historical_memory_states", %{models: models} do
    for {model, fsrs} <- models, entry <- model["memory_state"] do
      item = Fsrs.Item.new(Enum.map(entry["reviews"], &{&1["rating"], &1["delta_t"]}))
      starting_state = state(entry["starting_state"])
      context = context(model, entry)

      assert {:ok, memory_state} = Fsrs.memory_state(fsrs, item, starting_state)
      assert_state(memory_state, entry["memory_state"]["ok"], context)

      assert {:ok, history} = Fsrs.historical_memory_states(fsrs, item, starting_state)
      expected = entry["historical_memory_states"]["ok"]
      assert length(history) == length(expected), context
      Enum.zip(history, expected) |> Enum.each(fn {a, e} -> assert_state(a, e, context) end)
    end
  end

  test "memory_state_from_sm2", %{models: models} do
    for {model, fsrs} <- models, entry <- model["memory_state_from_sm2"] do
      actual =
        Fsrs.memory_state_from_sm2(
          fsrs,
          entry["ease_factor"],
          entry["interval"],
          entry["sm2_retention"]
        )

      context = context(model, entry)

      case entry["result"] do
        %{"ok" => expected} ->
          assert {:ok, memory_state} = actual, context
          assert_state(memory_state, expected, context)

        %{"error" => "InvalidInput"} ->
          assert actual == {:error, :invalid_input}, context
      end
    end
  end

  test "simulated review walks", %{models: models} do
    for {model, fsrs} <- models, walk <- model["walks"], step <- walk["steps"] do
      assert {:ok, next_states} =
               Fsrs.next_states_with_elapsed_days(
                 fsrs,
                 state(step["state"]),
                 step["desired_retention"],
                 step["days_elapsed"]
               )

      assert_next_states(next_states, step["next_states"], context(model, step))
    end
  end

  defp state(nil), do: nil

  defp state(map) do
    %MemoryState{
      stability: map["stability"],
      difficulty: map["difficulty"],
      stability_fast: map["stability_fast"]
    }
  end

  defp context(model, entry) do
    inputs = Map.drop(entry, ~w(result next_states memory_state historical_memory_states))
    "#{model["name"]}: #{inspect(inputs)}"
  end

  defp assert_next_states(next_states, expected, context) do
    for rating <- ~w(again hard good easy)a do
      item_state = Map.fetch!(next_states, rating)
      expected_item = Map.fetch!(expected, Atom.to_string(rating))
      context = "#{rating} of #{context}"

      assert_state(item_state.memory, expected_item["memory"], context)
      assert_close(item_state.interval, expected_item["interval"], "interval, " <> context)
    end
  end

  defp assert_state(%MemoryState{} = actual, expected, context) do
    assert_close(actual.stability, expected["stability"], "stability, " <> context)
    assert_close(actual.difficulty, expected["difficulty"], "difficulty, " <> context)
    assert_close(actual.stability_fast, expected["stability_fast"], "stability_fast, " <> context)
  end

  defp assert_close(actual, expected, context) do
    allowed = @tolerance * max(abs(expected), 1.0e-6)

    assert abs(actual - expected) <= allowed,
           "expected #{expected}, got #{actual} (#{context})"
  end
end
