defmodule Serialize.Bits do
  @moduledoc """
  Bit-width arithmetic for ranged integer encodings.

  `bits_required/2` is the defining arithmetic of the wire format
  (STANDARD.md "int"): the number of bits a ranged integer occupies is the
  bit length of `max - min`, and a degenerate range where `min == max`
  costs zero bits. BEAM integers are arbitrary precision, so one function
  covers the 32, 64 and 128 bit domains the reference implements as
  `bits_required`, `bits_required64` and `bits_required128`.
  """

  import Bitwise

  @doc """
  The number of bits required to serialize an integer in `[min, max]`.

  Exact at any width: the subtraction is performed on arbitrary precision
  integers, so ranges wider than the signed domain (the reference's
  unsigned-domain subtraction) are exact rather than overflowing.
  """
  @spec bits_required(non_neg_integer, non_neg_integer) :: non_neg_integer
  def bits_required(min, max) when is_integer(min) and is_integer(max) and min <= max do
    bit_length(max - min)
  end

  @doc """
  The bit length of a non-negative integer: 0 for 0, otherwise the index
  of the highest set bit plus one.
  """
  @spec bit_length(non_neg_integer) :: non_neg_integer
  def bit_length(value) when is_integer(value) and value >= 0 and value <= 0xFFFFFFFF do
    bit_length32(value)
  end

  def bit_length(value) when is_integer(value) and value > 0xFFFFFFFF do
    32 + bit_length(value >>> 32)
  end

  # A pure comparison search: no binary is built, every intermediate stays a
  # small integer, and the hot serialize_int widths (ranges within 32 bits)
  # resolve in at most five comparisons.
  defp bit_length32(value) when value >= 0x10000 do
    if value >= 0x1000000,
      do: 24 + top_bit_length(value >>> 24),
      else: 16 + top_bit_length(value >>> 16)
  end

  defp bit_length32(value) do
    if value >= 0x100,
      do: 8 + top_bit_length(value >>> 8),
      else: top_bit_length(value)
  end

  defp top_bit_length(byte) when byte >= 128, do: 8
  defp top_bit_length(byte) when byte >= 64, do: 7
  defp top_bit_length(byte) when byte >= 32, do: 6
  defp top_bit_length(byte) when byte >= 16, do: 5
  defp top_bit_length(byte) when byte >= 8, do: 4
  defp top_bit_length(byte) when byte >= 4, do: 3
  defp top_bit_length(byte) when byte >= 2, do: 2
  defp top_bit_length(1), do: 1
  defp top_bit_length(0), do: 0

  @doc "The all-ones mask of the given width."
  @spec mask(non_neg_integer) :: non_neg_integer
  def mask(bits) when is_integer(bits) and bits >= 0, do: (1 <<< bits) - 1
end
