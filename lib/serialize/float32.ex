defmodule Serialize.Float32 do
  @moduledoc """
  IEEE-754 arithmetic and bit-pattern conversion pinned to the wire's terms.

  BEAM float terms are always finite doubles: NaN and the infinities do not
  exist as terms, and bit-syntax float matching fails on their patterns. The
  wire's `float` and `double` operations are bit-transparent in both
  directions (STANDARD.md "Floating Point"), so this module converts through
  raw integer bit patterns and represents a non-finite pattern as
  `{:nonfinite, bits}` — the exact transmitted pattern, preserved so a round
  trip through this implementation reproduces all 32 (or 64) bits.

  `compressed_float` requires exact float32 arithmetic with every step
  rounding (STANDARD.md "compressed_float"). `round32/1` rounds a double to
  its nearest float32 through a bit-syntax round trip; emulating a float32
  add, subtract, multiply or divide as the double operation followed by
  `round32/1` is exact, because the double result carries at least
  2 x 24 + 2 significant bits, which makes the second rounding innocuous.
  """

  import Bitwise

  @typedoc """
  A value of the bit-transparent float operations: a finite float, or a
  non-finite IEEE-754 bit pattern carried verbatim as `{:nonfinite, bits}`.
  """
  @type value :: float | {:nonfinite, non_neg_integer}

  @doc """
  The 32-bit IEEE-754 pattern of a float value, for the write path.

  A float rounds to float32 first (the reference's `float` parameter type
  performs the same conversion at the call boundary); a float too large in
  magnitude for float32 is a caller error and raises. A `{:nonfinite, bits}`
  value passes its pattern through verbatim.
  """
  @spec bits32(value) :: non_neg_integer
  def bits32(value) when is_float(value) do
    <<bits::little-32>> = <<value::float-32-little>>

    if finite32?(bits) do
      bits
    else
      raise ArgumentError,
            "float #{value} overflows float32; pass {:nonfinite, bits} to write a non-finite pattern"
    end
  end

  def bits32({:nonfinite, bits})
      when is_integer(bits) and bits >= 0 and bits <= 0xFFFFFFFF do
    if finite32?(bits) do
      raise ArgumentError, "{:nonfinite, bits} carries a finite float32 pattern; pass the float"
    end

    bits
  end

  @doc """
  The value of a 32-bit IEEE-754 pattern, for the read path: the float for
  a finite pattern, `{:nonfinite, bits}` otherwise. Never raises — the bits
  come from untrusted data.
  """
  @spec value32(non_neg_integer) :: value
  def value32(bits) when is_integer(bits) and bits >= 0 and bits <= 0xFFFFFFFF do
    if finite32?(bits) do
      <<value::float-32-little>> = <<bits::little-32>>
      value
    else
      {:nonfinite, bits}
    end
  end

  @doc "The 64-bit IEEE-754 pattern of a double value, for the write path."
  @spec bits64(value) :: non_neg_integer
  def bits64(value) when is_float(value) do
    <<bits::little-64>> = <<value::float-64-little>>
    bits
  end

  def bits64({:nonfinite, bits})
      when is_integer(bits) and bits >= 0 and bits <= 0xFFFFFFFFFFFFFFFF do
    if finite64?(bits) do
      raise ArgumentError, "{:nonfinite, bits} carries a finite float64 pattern; pass the float"
    end

    bits
  end

  @doc """
  The value of a 64-bit IEEE-754 pattern, for the read path: the float for
  a finite pattern, `{:nonfinite, bits}` otherwise. Never raises.
  """
  @spec value64(non_neg_integer) :: value
  def value64(bits) when is_integer(bits) and bits >= 0 and bits <= 0xFFFFFFFFFFFFFFFF do
    if finite64?(bits) do
      <<value::float-64-little>> = <<bits::little-64>>
      value
    else
      {:nonfinite, bits}
    end
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
