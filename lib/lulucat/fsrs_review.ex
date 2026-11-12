defmodule Fsrs.Review do
  @moduledoc """
  One review in a card's history. Mirrors `fsrs::FSRSReview`.

  - `rating` — `1` (again) to `4` (easy)
  - `delta_t` — days since the previous review; may be fractional. It must be
    `0` for the first review of a card.

  中文说明：一次复习记录。`delta_t` 是距上一次复习的天数，可以是小数；
  卡片的第一次复习必须为 0。
  """

  @enforce_keys [:rating, :delta_t]
  defstruct [:rating, :delta_t]

  @type t :: %__MODULE__{rating: non_neg_integer(), delta_t: number()}

  @doc """
  Builds a review. `rating` may be an integer or a rating atom.

  ## Examples

      iex> Fsrs.Review.new(:good, 2.5)
      %Fsrs.Review{rating: 3, delta_t: 2.5}
  """
  @spec new(Fsrs.Rating.t() | non_neg_integer(), number()) :: t()
  def new(rating, delta_t) when is_number(delta_t) do
    %__MODULE__{rating: Fsrs.Rating.to_int(rating), delta_t: delta_t}
  end
end
