defmodule Fsrs.Math do
  @moduledoc false

  # Shared numeric limits, mirroring `S_MIN`, `S_MAX`, `D_MIN`, `D_MAX` and
  # `INIT_S_MAX` in fsrs-rs.

  def s_min, do: 0.0001
  def s_max, do: 36_500.0
  def d_min, do: 1.0
  def d_max, do: 10.0
  def init_s_max, do: 100.0

  @doc false
  def clamp(value, low, high), do: max(low, min(value, high))
end
