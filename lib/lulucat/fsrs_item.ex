defmodule Fsrs.Item do
  @moduledoc """
  A card's review history in chronological order. Mirrors `fsrs::FSRSItem`.

  中文说明：一张卡片按时间顺序排列的复习历史。
  """

  alias Fsrs.Review

  defstruct reviews: []

  @type t :: %__MODULE__{reviews: [Review.t()]}

  @doc """
  Builds an item from `Fsrs.Review` structs or `{rating, delta_t}` tuples.

  ## Examples

      iex> Fsrs.Item.new([{:good, 0}, {:hard, 3}])
      %Fsrs.Item{reviews: [
        %Fsrs.Review{rating: 3, delta_t: 0},
        %Fsrs.Review{rating: 2, delta_t: 3}
      ]}
  """
  @spec new([Review.t() | {Fsrs.Rating.t() | non_neg_integer(), number()}]) :: t()
  def new(reviews) when is_list(reviews) do
    %__MODULE__{
      reviews:
        Enum.map(reviews, fn
          %Review{} = review -> review
          {rating, delta_t} -> Review.new(rating, delta_t)
        end)
    }
  end
end
