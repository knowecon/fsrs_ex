defmodule Fsrs.NextStates do
  @moduledoc """
  The resulting state for each answer button. Mirrors `fsrs::NextStates`.

  中文说明：四个评分按钮各自对应的复习结果。
  """

  @enforce_keys [:again, :hard, :good, :easy]
  defstruct [:again, :hard, :good, :easy]

  @type t :: %__MODULE__{
          again: Fsrs.ItemState.t(),
          hard: Fsrs.ItemState.t(),
          good: Fsrs.ItemState.t(),
          easy: Fsrs.ItemState.t()
        }

  @doc """
  Returns the `Fsrs.ItemState` for a rating (`:again | :hard | :good | :easy`
  or `1..4`).

  ## Examples

      iex> {:ok, next_states} = Fsrs.next_states(Fsrs.default(), nil, 0.9, 0)
      iex> Fsrs.NextStates.fetch!(next_states, :good) == next_states.good
      true
  """
  @spec fetch!(t(), Fsrs.Rating.t() | 1..4) :: Fsrs.ItemState.t()
  def fetch!(%__MODULE__{} = next_states, rating) do
    case Fsrs.Rating.to_int(rating) do
      1 -> next_states.again
      2 -> next_states.hard
      3 -> next_states.good
      4 -> next_states.easy
      other -> raise ArgumentError, "rating must be between 1 and 4, got: #{inspect(other)}"
    end
  end
end
