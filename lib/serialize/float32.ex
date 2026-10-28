defmodule Serialize.Float32 do
  @moduledoc """
  IEEE-754 arithmetic and bit-pattern conversion pinned to the wire's terms.

  The wire's `float` and `double` carry finite values only (STANDARD.md
  "Finite values only, every one bit exact"), and BEAM float terms are
  exactly that: always finite doubles, never NaN or an infinity. So a value
  here is a plain float, converted through its raw integer bit pattern so
  -0.0 and the subnormals keep every bit. The read path tests the raw bits
  with `finite32?/1` and `finite64?/1` before converting — a non-finite
  pattern is refused, never converted.

  `compressed_float` requires exact float32 arithmetic with every step
  rounding (STANDARD.md "compressed_float"). `round32/1` rounds a double to
  its nearest float32 through a bit-syntax round trip; emulating a float32
  add, subtract, multiply or divide as the double operation followed by
  `round32/1` is exact, because the double result carries at least
  2 x 24 + 2 significant bits, which makes the second rounding innocuous.

  This module is a language necessity (IMPLEMENTING.md U15): the BEAM has
  no float32 type, so the float32 rounding and the float bit casts the
  reference gets from C++ for free are exported here, documented as such.
  `finite32?/1` and `finite64?/1` are the reference's
  `float_bits_are_finite` and `double_bits_are_finite`.
  """

  import Bitwise

  @typedoc "A value of the float operations: a finite float."
  @type value :: float

  @doc """
  The 32-bit IEEE-754 pattern of a float value, for the write path.

  A float rounds to float32 first (the reference's `float` parameter type
  performs the same conversion at the call boundary), and the check runs
  after that narrowing: a finite double too large in magnitude for float32
  narrows to an infinity, which the wire does not carry, so it is a caller
  error and raises.
  """
  @spec bits32(value) :: non_neg_integer
  def bits32(value) when is_float(value) do
    <<bits::little-32>> = <<value::float-32-little>>

    if finite32?(bits) do
      bits
    else
      raise ArgumentError, "float #{value} overflows float32: the wire carries finite values only"
    end
  end

  @doc """
  The value of a finite 32-bit IEEE-754 pattern, for the read path. The
  caller has already refused a non-finite pattern; handing one here raises.
  """
  @spec value32(non_neg_integer) :: value
  def value32(bits) when is_integer(bits) and bits >= 0 and bits <= 0xFFFFFFFF do
    unless finite32?(bits) do
      raise ArgumentError, "0x#{Integer.to_string(bits, 16)} is not a finite float32 pattern"
    end

    <<value::float-32-little>> = <<bits::little-32>>
    value
  end

  @doc "The 64-bit IEEE-754 pattern of a double value, for the write path."
  @spec bits64(value) :: non_neg_integer
  def bits64(value) when is_float(value) do
    <<bits::little-64>> = <<value::float-64-little>>
    bits
  end

  @doc """
  The value of a finite 64-bit IEEE-754 pattern, for the read path. The
  caller has already refused a non-finite pattern; handing one here raises.
  """
  @spec value64(non_neg_integer) :: value
  def value64(bits) when is_integer(bits) and bits >= 0 and bits <= 0xFFFFFFFFFFFFFFFF do
    unless finite64?(bits) do
      raise ArgumentError, "0x#{Integer.to_string(bits, 16)} is not a finite float64 pattern"
    end

    <<value::float-64-little>> = <<bits::little-64>>
    value
  end

  @doc "Whether a 32-bit pattern encodes a finite float32."
  @spec finite32?(non_neg_integer) :: boolean
  def finite32?(bits), do: (bits >>> 23 &&& 0xFF) != 0xFF

  @doc "Whether a 64-bit pattern encodes a finite float64."
  @spec finite64?(non_neg_integer) :: boolean
  def finite64?(bits), do: (bits >>> 52 &&& 0x7FF) != 0x7FF

  @doc """
  A number rounded to its nearest float32, as a double: the emulation of one
  float32 arithmetic step. Overflow to an infinity is reported as `:pos_inf`
  or `:neg_inf` so the compressed float clamps can resolve it the way the
  reference's float arithmetic does, instead of raising mid-quantization.
  """
  @spec round32(number) :: float | :pos_inf | :neg_inf
  def round32(value) when is_number(value) do
    <<bits::little-32>> = <<value::float-32-little>>

    if finite32?(bits) do
      <<rounded::float-32-little>> = <<bits::little-32>>
      rounded
    else
      if bits >>> 31 == 1, do: :neg_inf, else: :pos_inf
    end
  end

  @doc """
  A number rounded to its nearest float32, raising when the result is not
  finite: the conversion for declaration parameters, whose non-finite forms
  are non-conforming (STANDARD.md "compressed_float").
  """
  @spec round32!(number) :: float
  def round32!(value) do
    case round32(value) do
      rounded when is_float(rounded) -> rounded
      _ -> raise ArgumentError, "value #{value} is not finite in float32"
    end
  end
end
