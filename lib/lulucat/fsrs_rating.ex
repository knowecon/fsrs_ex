defmodule Fsrs.Rating do
  @moduledoc """
  Rating helpers.

  fsrs-rs uses plain integers for ratings. This module maps them to atoms:

  - `:again` => `1`
  - `:hard` => `2`
  - `:good` => `3`
  - `:easy` => `4`

  中文说明：评分的原子与整数互转。
  """

  @type t :: :again | :hard | :good | :easy

  @doc """
  Returns all ratings.
  """
  @spec all() :: [t()]
  def all, do: [:again, :hard, :good, :easy]

  @doc """
  Converts a rating atom to its integer. Non-negative integers pass through.

  ## Examples

      iex> Fsrs.Rating.to_int(:easy)
      4
      iex> Fsrs.Rating.to_int(2)
      2
  """
  @spec to_int(t() | non_neg_integer()) :: non_neg_integer()
  def to_int(:again), do: 1
  def to_int(:hard), do: 2
  def to_int(:good), do: 3
  def to_int(:easy), do: 4
  def to_int(rating) when is_integer(rating) and rating >= 0, do: rating

  @doc """
  Converts an integer rating to its atom.
  """
  @spec from_int(1..4) :: t()
  def from_int(1), do: :again
  def from_int(2), do: :hard
  def from_int(3), do: :good
  def from_int(4), do: :easy
end
