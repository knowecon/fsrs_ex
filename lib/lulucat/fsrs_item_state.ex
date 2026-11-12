defmodule Fsrs.ItemState do
  @moduledoc """
  The state of an item after a review. Mirrors `fsrs::ItemState`.

  `interval` is in days and is fractional; rounding it and applying a minimum
  is left to the caller.

  中文说明：一次复习后的结果，包含新的记忆状态和以天为单位的小数间隔。
  """

  @enforce_keys [:memory, :interval]
  defstruct [:memory, :interval]

  @type t :: %__MODULE__{memory: Fsrs.MemoryState.t(), interval: float()}
end
