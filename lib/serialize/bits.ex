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
  def bit_length(0), do: 0

  def bit_length(value) when is_integer(value) and value > 0 do
    bytes = :binary.encode_unsigned(value)
    <<top, _rest::binary>> = bytes
    (byte_size(bytes) - 1) * 8 + top_bit_length(top)
  end

  defp top_bit_length(byte) when byte >= 128, do: 8
  defp top_bit_length(byte) when byte >= 64, do: 7
  defp top_bit_length(byte) when byte >= 32, do: 6
  defp top_bit_length(byte) when byte >= 16, do: 5
  defp top_bit_length(byte) when byte >= 8, do: 4
  defp top_bit_length(byte) when byte >= 4, do: 3
  defp top_bit_length(byte) when byte >= 2, do: 2
  defp top_bit_length(1), do: 1

  @doc "The all-ones mask of the given width."
  @spec mask(non_neg_integer) :: non_neg_integer
  def mask(bits) when is_integer(bits) and bits >= 0, do: (1 <<< bits) - 1
end
