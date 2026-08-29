defmodule Serialize.Test.GoldenWire do
  @moduledoc """
  The family's cross-language conformance message: GoldenWireData,
  GoldenWireSerialize and golden_wire_bytes, ported operation for operation
  from serialize.h. The bytes are pinned forever — a failing pin here means
  the wire format changed, which is a breaking change and never something
  to fix by adjusting this module.
  """

  import Bitwise

  alias Serialize.Float32

  @int32_min -2_147_483_648
  @int32_max 2_147_483_647
  @int64_min -0x8000000000000000
  @int64_max 0x7FFFFFFFFFFFFFFF

  # serialize.h's golden_wire_bytes, copied mechanically from the reference
  # source: 112 bytes, 891 consumed bits, 5 trailing bits.
  @golden_wire_bytes <<0x5D, 0xDA, 0xF7, 0xE6, 0xD5, 0x77, 0xDF, 0x56, 0xEF, 0x9F, 0x75, 0x19,
                       0x52, 0xBC, 0xDA, 0x0F, 0x49, 0x40, 0xF4, 0x55, 0x55, 0x55, 0x55, 0x55,
                       0x55, 0x55, 0xFF, 0xFC, 0xD1, 0x48, 0xE0, 0x59, 0xD1, 0x48, 0xC0, 0x7B,
                       0xF3, 0x6A, 0xE2, 0x59, 0xD1, 0x48, 0x84, 0xB7, 0x06, 0xDE, 0xAD, 0xBE,
                       0xEF, 0xCA, 0xFE, 0x01, 0x06, 0x67, 0x6F, 0x6C, 0x64, 0x65, 0x6E, 0xE3,
                       0x21, 0x00, 0x00, 0xC0, 0x21, 0x00, 0x00, 0x00, 0x22, 0x00, 0x00, 0x00,
                       0xC0, 0x60, 0x00, 0x80, 0xA2, 0x7C, 0xFC, 0xEC, 0x26, 0xCB, 0xFF, 0xFF,
                       0x4B, 0x1D, 0x1F, 0xEF, 0xD2, 0x1A, 0x1F, 0x01, 0xE9, 0xFF, 0xFF, 0x09,
                       0x19, 0x2A, 0x3B, 0x4C, 0x5D, 0x6E, 0x7F, 0x78, 0x6F, 0x5E, 0x4D, 0x3C,
                       0x2B, 0x1A, 0x09, 0x04>>

  def golden_wire_bytes, do: @golden_wire_bytes
  def golden_bits, do: 891

  # GoldenWireInit, field for field. Fixed point fields carry the raw
  # scaled integers, exactly as the reference stores them.
  def values do
    %{
      bits4: 13,
      bits11: 1445,
      bits24: 11_259_375,
      bits32: 0xDEADBEEF,
      int_small: -37,
      int_full: -123_456_789,
      flag: true,
      float_value: Float32.round32!(3.1415926),
      compressed_float_value: 5.0,
      double_value: 1.0 / 3.0,
      uint8_value: 0x7F,
      uint16_value: 0x1234,
      uint32_value: 0x12345678,
      uint64_value: 0x123456789ABCDEF0,
      # difference of 1 from the base: the one-bit branch
      relative_near: 101,
      # difference of 2000 from the base: the 13-bit payload tier
      relative_far: 2100,
      bytes: <<0xDE, 0xAD, 0xBE, 0xEF, 0xCA, 0xFE, 0x01>>,
      string: "golden",
      # cyrillic, BMP only: explicit code points 0x043C 0x0438 0x0440
      wstring: "мир",
      # -3.25 in Q8.8
      fixed_q8_8: -(3 * 256 + 64),
      # 1234.5 in Q16.16
      fixed_q16_16: 1234 * 65536 + 32768,
      # -54321.1883... in Q48.16
      fixed_q48_16: -(54_321 * 65536 + 12_345),
      # 29999.99998... in Q16.16: every fraction bit set
      fixed_q16_16_unsigned: 29_999 * 65536 + 65_535,
      # -98765432109.066 in Q112.16: 75 bits on the wire, three groups
      fixed_q112_16_wide: -(98_765_432_109 * 65536 + 4321),
      # Q64.64 over the full unit range: 128 bits, four groups, every group distinct
      fixed_q64_64_wide: (0x0123456789ABCDEF <<< 64) + 0x0FEDCBA987654321
    }
  end

  # zeroed read-side holders, so a refused decode leaves comparable state
  def zero_values do
    values()
    |> Map.new(fn
      {:bytes, _v} -> {:bytes, <<0::56>>}
      {:string, _v} -> {:string, nil}
      {:wstring, _v} -> {:wstring, nil}
      {:flag, _v} -> {:flag, false}
      {key, _v} -> {key, 0}
    end)
  end

  # GoldenWireSerialize, operation for operation.
  def serialize(stream, d) do
    relative_base = 100

    with {:ok, stream, bits4} <- Serialize.serialize_bits(stream, d.bits4, 4),
         {:ok, stream, bits11} <- Serialize.serialize_bits(stream, d.bits11, 11),
         {:ok, stream, bits24} <- Serialize.serialize_bits(stream, d.bits24, 24),
         {:ok, stream, bits32} <- Serialize.serialize_bits(stream, d.bits32, 32),
         {:ok, stream, int_small} <- Serialize.serialize_int(stream, d.int_small, -100, 100),
         {:ok, stream, int_full} <-
           Serialize.serialize_int(stream, d.int_full, @int32_min, @int32_max),
         {:ok, stream, flag} <- Serialize.serialize_bool(stream, d.flag),
         {:ok, stream, float_value} <- Serialize.serialize_float(stream, d.float_value),
         {:ok, stream, compressed_float_value} <-
           Serialize.serialize_compressed_float(
             stream,
             d.compressed_float_value,
             0.0,
             10.0,
             0.01
           ),
         {:ok, stream, double_value} <- Serialize.serialize_double(stream, d.double_value),
         {:ok, stream, uint8_value} <- Serialize.serialize_uint8(stream, d.uint8_value),
         {:ok, stream, uint16_value} <- Serialize.serialize_uint16(stream, d.uint16_value),
         {:ok, stream, uint32_value} <- Serialize.serialize_uint32(stream, d.uint32_value),
         {:ok, stream, uint64_value} <- Serialize.serialize_uint64(stream, d.uint64_value),
         {:ok, stream, relative_near} <-
           Serialize.serialize_int_relative(stream, relative_base, d.relative_near),
         {:ok, stream, relative_far} <-
           Serialize.serialize_int_relative(stream, relative_base, d.relative_far),
         {:ok, stream} <- Serialize.serialize_align(stream),
         {:ok, stream, bytes} <- Serialize.serialize_bytes(stream, d.bytes, 7),
         {:ok, stream, string} <- Serialize.serialize_string(stream, d.string, 16),
         {:ok, stream, wstring} <- Serialize.serialize_wstring(stream, d.wstring, 8),
         # the fixed point section starts byte aligned, so every byte
         # pinned above it stays put
         {:ok, stream} <- Serialize.serialize_align(stream),
         {:ok, stream, fixed_q8_8} <-
           Serialize.serialize_fixed(stream, d.fixed_q8_8, 8, 8, -100, 100),
         {:ok, stream, fixed_q16_16} <-
           Serialize.serialize_fixed(stream, d.fixed_q16_16, 16, 16, -2000, 2000),
         {:ok, stream, fixed_q48_16} <-
           Serialize.serialize_fixed(stream, d.fixed_q48_16, 48, 16, -100_000, 100_000),
         {:ok, stream, fixed_q16_16_unsigned} <-
           Serialize.serialize_fixed(stream, d.fixed_q16_16_unsigned, 16, 16, 0, 30_000),
         # the wide fixed section starts byte aligned as well
         {:ok, stream} <- Serialize.serialize_align(stream),
         # +-2^57 units: 75 bits, the three-group structure
         {:ok, stream, fixed_q112_16_wide} <-
           Serialize.serialize_fixed(
             stream,
             d.fixed_q112_16_wide,
             112,
             16,
             -144_115_188_075_855_872,
             144_115_188_075_855_872
           ),
         # full unit range: 128 bits, the four-group structure
         {:ok, stream, fixed_q64_64_wide} <-
           Serialize.serialize_fixed(stream, d.fixed_q64_64_wide, 64, 64, @int64_min, @int64_max) do
      {:ok, stream,
       %{
         bits4: bits4,
         bits11: bits11,
         bits24: bits24,
         bits32: bits32,
         int_small: int_small,
         int_full: int_full,
         flag: flag,
         float_value: float_value,
         compressed_float_value: compressed_float_value,
         double_value: double_value,
         uint8_value: uint8_value,
         uint16_value: uint16_value,
         uint32_value: uint32_value,
         uint64_value: uint64_value,
         relative_near: relative_near,
         relative_far: relative_far,
         bytes: bytes,
         string: string,
         wstring: wstring,
         fixed_q8_8: fixed_q8_8,
         fixed_q16_16: fixed_q16_16,
         fixed_q48_16: fixed_q48_16,
         fixed_q16_16_unsigned: fixed_q16_16_unsigned,
         fixed_q112_16_wide: fixed_q112_16_wide,
         fixed_q64_64_wide: fixed_q64_64_wide
       }}
    end
  end

  @doc """
  Whether a decoded map equals the golden values exactly. Floats compare by
  bit pattern — the bit-transparent doctrine's terms: a tolerance
  comparison cannot see a quieted bit, and -0.0 == 0.0 by value.
  """
  def matches?(decoded, expected) do
    Enum.all?(Map.keys(expected), fn key ->
      exact_equal?(Map.get(decoded, key), Map.get(expected, key))
    end)
  end

  defp exact_equal?(a, b) when is_float(a) and is_float(b) do
    Float32.bits64(a) == Float32.bits64(b)
  end

  defp exact_equal?(a, b), do: a === b
end
