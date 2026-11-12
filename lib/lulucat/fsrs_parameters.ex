defmodule Fsrs.Parameters do
  @moduledoc false

  # Parameter defaults, validation and clipping. Mirrors `inference_v6.rs`,
  # `inference_v7.rs`, `check_and_fill_parameters` in `model.rs` and the
  # `parameter_clipper*.rs` files of fsrs-rs.

  import Fsrs.Math, only: [clamp: 3]

  @s_min Fsrs.Math.s_min()
  @d_min Fsrs.Math.d_min()
  @d_max Fsrs.Math.d_max()
  @init_s_max Fsrs.Math.init_s_max()

  @fsrs5_default_decay 0.5
  @fsrs6_default_decay 0.1542

  @fsrs7_param_len 34
  @fsrs6_param_len 21

  @default_parameters [
    0.1104,
    2.2395,
    3.9221,
    11.7841,
    6.1686,
    0.6457,
    3.6807,
    1.9795,
    0.0,
    1.3826,
    0.7024,
    0.5999,
    0.8146,
    0.6398,
    1.0,
    1.3207,
    0.6707,
    3.8668,
    0.4416,
    0.0934,
    1.8631,
    0.6162,
    1.0869,
    0.1567,
    0.0801,
    0.2421,
    0.9464,
    0.1433,
    0.7145,
    0.0,
    0.5667,
    0.3734,
    0.5333,
    0.3048
  ]

  @fsrs6_default_parameters [
    0.212,
    1.2931,
    2.3065,
    8.2956,
    6.4133,
    0.8334,
    3.0194,
    0.001,
    1.8722,
    0.1666,
    0.796,
    1.4835,
    0.0614,
    0.2629,
    1.6483,
    0.6014,
    1.8729,
    0.5425,
    0.0912,
    0.0658,
    @fsrs6_default_decay
  ]

  def default_parameters, do: @default_parameters
  def fsrs6_default_parameters, do: @fsrs6_default_parameters
  def fsrs5_default_decay, do: @fsrs5_default_decay
  def fsrs6_default_decay, do: @fsrs6_default_decay

  @doc false
  def version_from_param_count(count) when count == 0 or count == @fsrs7_param_len, do: :fsrs7
  def version_from_param_count(_count), do: :fsrs6

  @doc false
  def check_and_fill(parameters) when is_tuple(parameters) do
    check_and_fill(Tuple.to_list(parameters))
  end

  def check_and_fill(parameters) when is_list(parameters) do
    if Enum.all?(parameters, &is_number/1) do
      parameters = Enum.map(parameters, &(&1 * 1.0))

      case version_from_param_count(length(parameters)) do
        :fsrs6 -> fill_fsrs6(parameters)
        :fsrs7 -> fill_fsrs7(parameters)
      end
    else
      {:error, :invalid_parameters}
    end
  end

  def check_and_fill(_parameters), do: {:error, :invalid_parameters}

  defp fill_fsrs7([]), do: {:ok, @default_parameters}
  defp fill_fsrs7(parameters), do: {:ok, parameters}

  defp fill_fsrs6(parameters) do
    case length(parameters) do
      17 ->
        [w4, w5, w6] = Enum.slice(parameters, 4, 3)

        # fsrs-rs yields NaN (rejected as invalid) when the logarithm is undefined.
        if w5 * 3.0 + 1.0 > 0.0 do
          parameters =
            parameters
            |> List.replace_at(4, w5 * 2.0 + w4)
            |> List.replace_at(5, :math.log(w5 * 3.0 + 1.0) / 3.0)
            |> List.replace_at(6, w6 + 0.5)

          {:ok, parameters ++ [0.0, 0.0, 0.0, @fsrs5_default_decay]}
        else
          {:error, :invalid_parameters}
        end

      19 ->
        {:ok, parameters ++ [0.0, @fsrs5_default_decay]}

      @fsrs6_param_len ->
        {:ok, parameters}

      _ ->
        {:error, :invalid_parameters}
    end
  end

  @doc false
  # Clips a filled parameter list the way `FSRS::new` does: one relearning
  # step and short-term stability enabled.
  def clip(parameters) when length(parameters) == @fsrs7_param_len do
    clip_fsrs7(List.to_tuple(parameters))
  end

  def clip(parameters) when length(parameters) == @fsrs6_param_len do
    w17_w18_ceiling = 2.0
    w19_floor = 0.01

    clamps = [
      {@s_min, @init_s_max},
      {@s_min, @init_s_max},
      {@s_min, @init_s_max},
      {@s_min, @init_s_max},
      {@d_min, @d_max},
      {0.001, 4.0},
      {0.001, 4.0},
      {0.001, 0.75},
      {0.0, 4.5},
      {0.0, 0.8},
      {0.001, 3.5},
      {0.001, 5.0},
      {0.001, 0.25},
      {0.001, 0.9},
      {0.0, 4.0},
      {0.0, 1.0},
      {1.0, 6.0},
      {0.0, w17_w18_ceiling},
      {0.0, w17_w18_ceiling},
      {w19_floor, 0.8},
      {0.1, 0.8}
    ]

    parameters
    |> Enum.zip(clamps)
    |> Enum.map(fn {w, {low, high}} -> clamp(w, low, high) end)
  end

  defp clip_fsrs7(w) do
    w0 = clamp(elem(w, 0), @s_min, @init_s_max / 2.0)
    w1 = clamp(elem(w, 1), w0, @init_s_max)
    w2 = clamp(elem(w, 2), w1, @init_s_max)
    w3 = clamp(elem(w, 3), w2, @init_s_max)

    w25 = clamp(elem(w, 25), 0.2, 0.85)
    # srs-benchmark: w26 in [0.5, 0.99], then w26 >= w25.
    w26 = clamp(elem(w, 26), max(w25, 0.5), 0.99)

    [
      w0,
      w1,
      w2,
      w3,
      clamp(elem(w, 4), 1.0, 10.0),
      clamp(elem(w, 5), 0.001, 4.0),
      clamp(elem(w, 6), 0.1, 4.0),
      clamp(elem(w, 7), 0.0, 4.0),
      clamp(elem(w, 8), 0.0, 1.2),
      clamp(elem(w, 9), 0.3, 3.0),
      clamp(elem(w, 10), 0.01, 1.5),
      clamp(elem(w, 11), 0.1, 1.0),
      clamp(elem(w, 12), 0.0, 3.5),
      clamp(elem(w, 13), 0.0, 1.0),
      clamp(elem(w, 14), 1.0, 7.0),
      clamp(elem(w, 15), 0.0, 4.0),
      clamp(elem(w, 16), 0.0, 2.0),
      clamp(elem(w, 17), 0.5, 6.0),
      clamp(elem(w, 18), 0.001, 1.5),
      clamp(elem(w, 19), 0.001, 1.0),
      clamp(elem(w, 20), 0.0, 5.0),
      clamp(elem(w, 21), 0.0, 1.0),
      clamp(elem(w, 22), 1.0, 7.0),
      clamp(elem(w, 23), 0.01, 0.25),
      clamp(elem(w, 24), 0.01, 0.95),
      w25,
      w26,
      clamp(elem(w, 27), 0.01, 1.0),
      clamp(elem(w, 28), 0.1, 1.0),
      clamp(elem(w, 29), 0.0, 0.9),
      clamp(elem(w, 30), 0.1, 1.1),
      clamp(elem(w, 31), 0.0, 1.0),
      clamp(elem(w, 32), 0.0, 0.6),
      clamp(elem(w, 33), 0.0, 0.6)
    ]
  end
end
