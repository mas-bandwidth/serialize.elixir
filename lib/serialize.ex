defmodule Serialize do
  @moduledoc """
  Bitpacked binary serialization: the serialize wire format on the BEAM,
  byte-identical to the C, C++, C#, Go, Rust, JavaScript, Dart and Java
  implementations. STANDARD.md is the authority on every byte.

  Every operation is unified over the three streams — `Serialize.WriteStream`,
  `Serialize.ReadStream` and `Serialize.MeasureStream` — so one serialize
  function per message covers writing, reading and measuring, the family's
  single-function pattern. Streams are immutable: each operation returns

    * `{:ok, stream, value}` — the advanced stream, and the value written
      (echoed) or read (decoded);
    * `{:ok, stream}` — for `serialize_align/1`;
    * `{:error, stream}` — a read refusal, the reference's `false` return.

  Writes assume trusted data: caller contract violations raise
  `ArgumentError`, this implementation's misuse convention. Reads validate
  always — hostile bytes refuse as values and never raise.

  A refusal hands back no value at all: `{:error, stream}` has no third
  element, so nothing can be mistaken for a decoded value. It is also
  terminal — nothing after the failing operation has a defined position —
  and the stream enforces that: the refusal latches the read stream
  failed, and every later read on it refuses without consuming bits. See
  `Serialize.ReadStream`.

  Compose messages with plain function calls (`with` chains); the
  reference's `serialize_object` is composition, contributes no bytes, and
  needs no operation here.

  Non-finite floating point values cannot exist as BEAM float terms, so the
  bit-transparent `serialize_float/2` and `serialize_double/2` carry them
  as `{:nonfinite, bits}` — the exact IEEE-754 pattern, preserved through a
  round trip. See `Serialize.Float32`.
  """

  import Bitwise

  alias Serialize.{Bits, Float32, MeasureStream, ReadStream, WriteStream}

  @type stream :: WriteStream.t() | ReadStream.t() | MeasureStream.t()
  @type result(value) :: {:ok, stream, value} | {:error, stream}

  @int32_min -0x80000000
  @int32_max 0x7FFFFFFF
  @int64_min -0x8000000000000000
  @int64_max 0x7FFFFFFFFFFFFFFF
  @int128_min -0x80000000000000000000000000000000
  @int128_max 0x7FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF
  @uint64_max 0xFFFFFFFFFFFFFFFF
  @uint128_max 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF

  # ------------------------------------------------------------------
  # bits
  # ------------------------------------------------------------------

  @doc """
  Serializes the low `bits` bits of an unsigned value, `bits` in `[1, 64]`.
  For `bits > 32` the low 32 bits are written first as one group, then the
  high remainder as a second group (STANDARD.md "bits").
  """
  @spec serialize_bits(stream, non_neg_integer, 1..64) :: result(non_neg_integer)
  def serialize_bits(%WriteStream{} = stream, value, bits)
      when is_integer(bits) and bits >= 1 and bits <= 32 do
    WriteStream.serialize_bits(stream, value, bits)
  end

  def serialize_bits(%ReadStream{} = stream, value, bits)
      when is_integer(bits) and bits >= 1 and bits <= 32 do
    ReadStream.serialize_bits(stream, value, bits)
  end

  def serialize_bits(%MeasureStream{} = stream, value, bits)
      when is_integer(bits) and bits >= 1 and bits <= 32 do
    MeasureStream.serialize_bits(stream, value, bits)
  end

  def serialize_bits(%WriteStream{} = stream, value, bits)
      when is_integer(bits) and bits > 32 and bits <= 64 do
    unless is_integer(value) and value >= 0 and value <= @uint64_max do
      raise ArgumentError, "serialize_bits value must be an integer in [0, 2^64-1]"
    end

    # the reference's truncation check is per 32-bit group: the low group
    # truncates silently, the high group must fit its width
    unless value >>> 32 <= Bits.mask(bits - 32) do
      raise ArgumentError, "serialize_bits value #{value} does not fit #{bits} bits"
    end

    {:ok, stream, _} = WriteStream.serialize_bits(stream, value &&& 0xFFFFFFFF, 32)
    {:ok, stream, _} = WriteStream.serialize_bits(stream, value >>> 32, bits - 32)
    {:ok, stream, value}
  end

  def serialize_bits(%ReadStream{} = stream, _value, bits)
      when is_integer(bits) and bits > 32 and bits <= 64 do
    with {:ok, stream, lo} <- ReadStream.serialize_bits(stream, 0, 32),
         {:ok, stream, hi} <- ReadStream.serialize_bits(stream, 0, bits - 32) do
      {:ok, stream, hi <<< 32 ||| lo}
    end
  end

  def serialize_bits(%MeasureStream{} = stream, value, bits)
      when is_integer(bits) and bits > 32 and bits <= 64 do
    {:ok, stream, _} = MeasureStream.serialize_bits(stream, 0, 32)
    {:ok, stream, _} = MeasureStream.serialize_bits(stream, 0, bits - 32)
    {:ok, stream, value}
  end

  @doc "Serializes an unsigned 8-bit integer: `serialize_bits/3` at width 8."
  @spec serialize_uint8(stream, non_neg_integer) :: result(non_neg_integer)
  def serialize_uint8(stream, value), do: serialize_bits(stream, value, 8)

  @doc "Serializes an unsigned 16-bit integer: `serialize_bits/3` at width 16."
  @spec serialize_uint16(stream, non_neg_integer) :: result(non_neg_integer)
  def serialize_uint16(stream, value), do: serialize_bits(stream, value, 16)

  @doc "Serializes an unsigned 32-bit integer: `serialize_bits/3` at width 32."
  @spec serialize_uint32(stream, non_neg_integer) :: result(non_neg_integer)
  def serialize_uint32(stream, value), do: serialize_bits(stream, value, 32)

  @doc """
  Serializes an unsigned 64-bit integer: `serialize_bits/3` at width 64 —
  low 32 bits then high 32. Not ranged; always costs 64 bits.
  """
  @spec serialize_uint64(stream, non_neg_integer) :: result(non_neg_integer)
  def serialize_uint64(stream, value), do: serialize_bits(stream, value, 64)

  @doc """
  Serializes an unsigned 128-bit integer: the low 64-bit half first, then
  the high half, each as `serialize_bits/3` at width 64. Not ranged; always
  costs 128 bits.
  """
  @spec serialize_uint128(stream, non_neg_integer) :: result(non_neg_integer)
  def serialize_uint128(stream, value) do
    {lo, hi} =
      if writing?(stream) do
        unless is_integer(value) and value >= 0 and value <= @uint128_max do
          raise ArgumentError, "serialize_uint128 value must be an integer in [0, 2^128-1]"
        end

        {value &&& @uint64_max, value >>> 64}
      else
        {0, 0}
      end

    with {:ok, stream, lo} <- serialize_bits(stream, lo, 64),
         {:ok, stream, hi} <- serialize_bits(stream, hi, 64) do
      {:ok, stream, if(reading?(stream), do: hi <<< 64 ||| lo, else: value)}
    end
  end

  # ------------------------------------------------------------------
  # bool
  # ------------------------------------------------------------------

  @doc "Serializes a boolean as one bit: 1 for true, 0 for false."
  @spec serialize_bool(stream, boolean) :: result(boolean)
  def serialize_bool(%ReadStream{} = stream, _value) do
    with {:ok, stream, bit} <- ReadStream.serialize_bits(stream, 0, 1) do
      {:ok, stream, bit == 1}
    end
  end

  def serialize_bool(stream, value) do
    unless is_boolean(value) do
      raise ArgumentError, "serialize_bool value must be a boolean"
    end

    {:ok, stream, _bit} = serialize_bits(stream, if(value, do: 1, else: 0), 1)
    {:ok, stream, value}
  end

  # ------------------------------------------------------------------
  # ranged integers
  # ------------------------------------------------------------------

  @doc """
  Serializes a ranged 32-bit integer in `bits_required(min, max)` bits as
  its offset from `min`. A degenerate range where `min == max` costs zero
  bits. The reader rejects a decoded offset outside the range.
  """
  @spec serialize_int(stream, integer, integer, integer) :: result(integer)
  def serialize_int(%WriteStream{} = stream, value, min, max)
      when is_integer(min) and is_integer(max) and min >= @int32_min and max <= @int32_max and
             min <= max do
    WriteStream.serialize_integer(stream, value, min, max)
  end

  def serialize_int(%ReadStream{} = stream, value, min, max)
      when is_integer(min) and is_integer(max) and min >= @int32_min and max <= @int32_max and
             min <= max do
    ReadStream.serialize_integer(stream, value, min, max)
  end

  def serialize_int(%MeasureStream{} = stream, value, min, max)
      when is_integer(min) and is_integer(max) and min >= @int32_min and max <= @int32_max and
             min <= max do
    MeasureStream.serialize_integer(stream, value, min, max)
  end

  @doc """
  Serializes a ranged 64-bit integer: a single group for 32 bits or fewer,
  otherwise the low 32 bits then the high remainder. Not to be confused
  with `serialize_uint64/2`, which is not ranged.
  """
  @spec serialize_int64(stream, integer, integer, integer) :: result(integer)
  def serialize_int64(stream, value, min, max)
      when is_integer(min) and is_integer(max) and min >= @int64_min and max <= @int64_max and
             min <= max do
    smod(stream).serialize_integer64(stream, value, min, max)
  end

  @doc """
  Serializes a ranged 128-bit integer in 32-bit groups from least
  significant upward. Where the range fits 64 bits the bytes are identical
  to `serialize_int64/4` over the same bounds. `min <= max` is the legal
  relation here exactly as at the narrower widths: a degenerate range where
  `min == max` costs zero bits, the writer emits nothing, the reader
  consumes nothing and takes the value from `min`, and a measure adds zero.
  """
  @spec serialize_int128(stream, integer, integer, integer) :: result(integer)
  def serialize_int128(stream, value, min, max)
      when is_integer(min) and is_integer(max) and min >= @int128_min and max <= @int128_max and
             min <= max do
    smod(stream).serialize_integer128(stream, value, min, max)
  end

  # ------------------------------------------------------------------
  # floating point
  # ------------------------------------------------------------------

  @doc """
  Serializes the 32 bits of an IEEE-754 single-precision value as one
  32-bit group — bit-transparent in both directions. A non-finite pattern
  travels as `{:nonfinite, bits}` (see `Serialize.Float32`).
  """
  @spec serialize_float(stream, Float32.value()) :: result(Float32.value())
  def serialize_float(%ReadStream{} = stream, _value) do
    with {:ok, stream, pattern} <- ReadStream.serialize_bits(stream, 0, 32) do
      {:ok, stream, Float32.value32(pattern)}
    end
  end

  def serialize_float(stream, value) do
    {:ok, stream, _pattern} = serialize_bits(stream, Float32.bits32(value), 32)
    {:ok, stream, value}
  end

  @doc """
  Serializes the 64 bits of an IEEE-754 double-precision value as one
  64-bit group — bit-transparent in both directions. A non-finite pattern
  travels as `{:nonfinite, bits}`.
  """
  @spec serialize_double(stream, Float32.value()) :: result(Float32.value())
  def serialize_double(%ReadStream{} = stream, _value) do
    with {:ok, stream, pattern} <- serialize_bits(stream, 0, 64) do
      {:ok, stream, Float32.value64(pattern)}
    end
  end

  def serialize_double(stream, value) do
    {:ok, stream, _pattern} = serialize_bits(stream, Float32.bits64(value), 64)
    {:ok, stream, value}
  end

  @doc """
  Serializes a float quantized to a resolution over `[min, max]`
  (STANDARD.md "compressed_float"). The quantization arithmetic is float32
  with two roundings on each side, emulated exactly; the declaration must
  be finite in float32 and writing a non-finite value is non-conforming —
  both raise. The reader rejects an integer above the step count. Lossy by
  construction: a round trip returns the nearest representable quantum.
  """
  @spec serialize_compressed_float(stream, number, number, number, number) :: result(float)
  def serialize_compressed_float(stream, value, min, max, res) do
    {miv, bits, delta, min32} = compressed_float_params(min, max, res)

    integer_value =
      if writing?(stream) do
        unless is_number(value) do
          raise ArgumentError, "serialize_compressed_float value must be a finite number"
        end

        compressed_float_quantize(value, min32, delta, miv)
      else
        0
      end

    with {:ok, stream, integer_value} <- serialize_bits(stream, integer_value, bits) do
      cond do
        not reading?(stream) -> {:ok, stream, value}
        integer_value > miv -> refuse(stream)
        true -> {:ok, stream, compressed_float_decode(integer_value, miv, delta, min32)}
      end
    end
  end

  # Derives the wire constants from a declaration, mirroring
  # serialize_compressed_float_params: every step float32, the parameters
  # rounding at this boundary exactly as the reference's float parameters
  # do. A declaration whose delta or step count is not finite in float32 is
  # non-conforming and raises.
  defp compressed_float_params(min, max, res)
       when is_number(min) and is_number(max) and is_number(res) do
    min32 = Float32.round32!(min * 1.0)
    max32 = Float32.round32!(max * 1.0)
    res32 = Float32.round32!(res * 1.0)

    unless min32 < max32 and res32 > 0 do
      raise ArgumentError, "serialize_compressed_float requires min < max and res > 0"
    end

    delta = Float32.round32!(max32 - min32)
    values = Float32.round32!(delta / res32)

    values =
      cond do
        values < 1.0 -> 1.0
        # largest float32 below 2^32
        values > 4_294_967_040.0 -> 4_294_967_040.0
        true -> values
      end

    max_integer_value = trunc(Float.ceil(values))
    {max_integer_value, Bits.bits_required(0, max_integer_value), delta, min32}
  end

  # The writer's quantization, exactly the reference's float32 steps: the
  # normalized value clamps to [0,1], the product rounds to float32 BEFORE
  # 0.5 is added, that sum rounds before the floor, and the floored integer
  # clamps to the step count (the normative integer clamp, STANDARD.md
  # 2026-08-23). A value whose float32 form overflows behaves as the
  # reference's infinity does: it clamps.
  defp compressed_float_quantize(value, min32, delta, miv) do
    difference =
      case Float32.round32(value * 1.0) do
        :pos_inf -> :pos_inf
        :neg_inf -> :neg_inf
        v32 -> Float32.round32(v32 - min32)
      end

    normalized =
      case difference do
        :pos_inf -> 1.0
        :neg_inf -> 0.0
        d -> clamp01(Float32.round32(d / delta))
      end

    scaled = Float32.round32!(normalized * Float32.round32!(miv * 1.0))
    integer = trunc(Float.floor(Float32.round32!(scaled + 0.5)))
    min(integer, miv)
  end

  defp clamp01(:pos_inf), do: 1.0
  defp clamp01(:neg_inf), do: 0.0
  defp clamp01(n) when n < 0.0, do: 0.0
  defp clamp01(n) when n > 1.0, do: 1.0
  defp clamp01(n), do: n

  # The reader's arithmetic, pinned the same way: the quotient rounds, the
  # product rounds BEFORE min is added, and the sum rounds — float32
  # throughout, never fused, never widened.
  defp compressed_float_decode(integer, miv, delta, min32) do
    quotient = Float32.round32!(Float32.round32!(integer * 1.0) / Float32.round32!(miv * 1.0))
    scaled = Float32.round32!(quotient * delta)

    # the final add cannot overflow for a conforming declaration; the
    # non-finite mapping keeps the never-raise reader obligation airtight
    case Float32.round32(scaled + min32) do
      :pos_inf -> {:nonfinite, 0x7F800000}
      :neg_inf -> {:nonfinite, 0xFF800000}
      value -> value
    end
  end

  # ------------------------------------------------------------------
  # int_relative
  # ------------------------------------------------------------------

  # the flag ladder's payload tiers: {min, max} of serialize_int per tier
  @relative_tiers [{2, 6}, {7, 23}, {24, 280}, {281, 4377}, {4378, 69_914}]

  # the int_relative domain: 0 to 2^31 - 1 inclusive, a property of the
  # operation rather than of the caller's storage type
  @relative_max 0x7FFFFFFF

  @doc """
  Serializes `current` relative to `previous`, where `current > previous`
  (STANDARD.md "int_relative"): a ladder of one-bit flags with a payload
  sized to the difference, and `current` itself as 32 raw bits at the final
  tier.

  The domain is `0` to `2^31 - 1` inclusive, and both `previous` and
  `current` lie in it. `previous` is caller state and never arrives off the
  wire, so one outside the domain is caller error: the guard rejects it.
  The reader reconstructs `current` on BEAM integers, which cannot wrap at
  any width, then refuses the read unless the result lies in the domain and
  is strictly greater than `previous` — in the one-bit tier, in each of the
  five bounded tiers, and in the absolute tier alike. Positive only,
  strictly increasing, no wrapping.
  """
  @spec serialize_int_relative(stream, 0..0x7FFFFFFF, 0..0x7FFFFFFF | nil) ::
          result(non_neg_integer)
  def serialize_int_relative(stream, previous, current)
      when is_integer(previous) and previous >= 0 and previous <= @relative_max do
    difference =
      if writing?(stream) do
        unless is_integer(current) and current > previous and current <= @relative_max do
          raise ArgumentError, "serialize_int_relative requires previous < current <= 2^31-1"
        end

        current - previous
      else
        0
      end

    with {:ok, stream, one_bit} <- serialize_bool(stream, writing?(stream) and difference == 1) do
      if one_bit do
        relative_result(stream, previous, previous + 1, current)
      else
        relative_tiers(stream, previous, current, difference, @relative_tiers)
      end
    end
  end

  defp relative_tiers(stream, previous, current, difference, [{lo, hi} | rest]) do
    with {:ok, stream, flag} <- serialize_bool(stream, writing?(stream) and difference <= hi) do
      if flag do
        payload = if writing?(stream), do: difference, else: lo

        with {:ok, stream, d} <- serialize_int(stream, payload, lo, hi) do
          relative_result(stream, previous, previous + d, current)
        end
      else
        relative_tiers(stream, previous, current, difference, rest)
      end
    end
  end

  # the final tier transmits current itself, not the difference: at full
  # width the subtraction buys nothing, and the absolute form lets the
  # reader check the ordering directly. The 32 raw bits are unsigned —
  # serialize_bits decodes an unsigned group — so a value with the top bit
  # set is outside the domain and the check below refuses it.
  defp relative_tiers(stream, previous, current, _difference, []) do
    payload = if writing?(stream), do: current, else: 0

    with {:ok, stream, value} <- serialize_bits(stream, payload, 32) do
      relative_result(stream, previous, value, current)
    end
  end

  # The reconstruction check every tier owes: `reconstructed` is computed on
  # arbitrary precision BEAM integers, so it cannot wrap, and the read is
  # refused unless it lies in the domain and above `previous`.
  defp relative_result(stream, previous, reconstructed, current) do
    cond do
      not reading?(stream) -> {:ok, stream, current}
      reconstructed > @relative_max -> refuse(stream)
      reconstructed <= previous -> refuse(stream)
      true -> {:ok, stream, reconstructed}
    end
  end

  # ------------------------------------------------------------------
  # fixed point
  # ------------------------------------------------------------------

  @doc """
  Serializes a fixed point value (STANDARD.md "fixed"): `value` is the raw
  scaled integer of a Q format `integer_bits.fraction_bits`, and `min` and
  `max` are bounds in whole units. The raw offset from `min <<<
  fraction_bits` is written in exactly the bit length of the raw range,
  split into 32-bit groups from least significant upward. A degenerate
  range where `min == max` costs zero bits on every storage width. The
  round trip is exact; the reader rejects an offset above the raw range.
  """
  @spec serialize_fixed(stream, integer, pos_integer, non_neg_integer, integer, integer) ::
          result(integer)
  def serialize_fixed(stream, value, integer_bits, fraction_bits, min, max) do
    {raw_min, raw_range, bits} = fixed_params(integer_bits, fraction_bits, min, max)

    cond do
      bits == 0 ->
        if match?(%WriteStream{}, stream) and value != raw_min do
          raise ArgumentError, "serialize_fixed value #{value} outside its degenerate range"
        end

        {:ok, stream, raw_min}

      true ->
        offset =
          if writing?(stream) do
            unless is_integer(value) and value >= raw_min and value - raw_min <= raw_range do
              raise ArgumentError,
                    "serialize_fixed value #{value} outside [#{min}, #{max}] whole units"
            end

            value - raw_min
          else
            0
          end

        with {:ok, stream, offset} <- serialize_groups(stream, offset, bits) do
          cond do
            not reading?(stream) -> {:ok, stream, value}
            offset > raw_range -> refuse(stream)
            true -> {:ok, stream, raw_min + offset}
          end
        end
    end
  end

  # The declaration arithmetic: the Q format must fill one of the storage
  # widths, the bounds must be int64 whole units that fit the format's
  # capacity — signed when min is negative, with the sign bit counting
  # toward integer_bits — and the wire cost is the bit length of the raw
  # range. All one lane: BEAM integers cover every storage width.
  defp fixed_params(integer_bits, fraction_bits, min, max) do
    unless is_integer(integer_bits) and integer_bits >= 1 and is_integer(fraction_bits) and
             fraction_bits >= 0 and (integer_bits + fraction_bits) in [8, 16, 32, 64, 128] do
      raise ArgumentError,
            "serialize_fixed integer_bits + fraction_bits must equal a storage width (8/16/32/64/128)"
    end

    unless is_integer(min) and is_integer(max) and min >= @int64_min and max <= @int64_max and
             min <= max do
      raise ArgumentError, "serialize_fixed bounds must be int64 whole units with min <= max"
    end

    capacity_ok? =
      if min < 0 do
        (integer_bits >= 65 or min >= -(1 <<< (integer_bits - 1))) and
          (integer_bits >= 64 or max <= (1 <<< (integer_bits - 1)) - 1)
      else
        integer_bits >= 64 or max <= (1 <<< integer_bits) - 1
      end

    unless capacity_ok? do
      raise ArgumentError, "serialize_fixed bounds in whole units do not fit the Q format"
    end

    raw_min = min <<< fraction_bits
    raw_range = (max - min) <<< fraction_bits
    {raw_min, raw_range, Bits.bits_required(0, raw_range)}
  end

  # ------------------------------------------------------------------
  # align, bytes, strings
  # ------------------------------------------------------------------

  @doc """
  Serializes an alignment: zero bits pad to the next byte boundary, and the
  reader verifies the padding is zero.
  """
  @spec serialize_align(stream) :: {:ok, stream} | {:error, stream}
  def serialize_align(%WriteStream{} = stream), do: WriteStream.serialize_align(stream)
  def serialize_align(%ReadStream{} = stream), do: ReadStream.serialize_align(stream)
  def serialize_align(%MeasureStream{} = stream), do: MeasureStream.serialize_align(stream)

  @doc """
  Serializes `count` raw bytes, aligning first — the alignment is part of
  the format, performed even when `count` is zero. `count` is not written;
  both sides must agree on it. On read, `data` is ignored and the bytes
  come back as a sub-binary of the stream's data.
  """
  @spec serialize_bytes(stream, binary | nil, non_neg_integer) :: result(binary)
  def serialize_bytes(%WriteStream{} = stream, data, count) when is_integer(count) do
    WriteStream.serialize_bytes(stream, data, count)
  end

  def serialize_bytes(%ReadStream{} = stream, data, count) when is_integer(count) do
    ReadStream.serialize_bytes(stream, data, count)
  end

  def serialize_bytes(%MeasureStream{} = stream, data, count) when is_integer(count) do
    MeasureStream.serialize_bytes(stream, data, count)
  end

  @doc """
  Serializes a UTF-8 string (STANDARD.md "string"): the length as
  `serialize_int(length, 0, buffer_size - 1)`, then the bytes via the
  aligning bytes operation. The payload is well-formed UTF-8 with no
  interior NUL by writer contract — unchecked on write, per the trusted
  writes doctrine — and the reader refuses a payload violating either rule.
  """
  @spec serialize_string(stream, String.t() | nil, pos_integer) :: result(String.t())
  def serialize_string(stream, value, buffer_size)
      when is_integer(buffer_size) and buffer_size >= 1 and buffer_size <= @int32_max do
    length =
      if writing?(stream) do
        unless is_binary(value) and byte_size(value) < buffer_size do
          raise ArgumentError, "serialize_string value must be a binary shorter than buffer_size"
        end

        byte_size(value)
      else
        0
      end

    with {:ok, stream, length} <- serialize_int(stream, length, 0, buffer_size - 1),
         {:ok, stream, payload} <- serialize_bytes(stream, value, length) do
      if reading?(stream) do
        # refusal order per the reference: the interior-NUL scan, then
        # UTF-8 validation. NUL is valid UTF-8, which is why it is its own
        # rule: a zero byte gives the payload two lengths.
        cond do
          :binary.match(payload, <<0>>) != :nomatch -> refuse(stream)
          not String.valid?(payload) -> refuse(stream)
          true -> {:ok, stream, payload}
        end
      else
        {:ok, stream, value}
      end
    end
  end

  @doc """
  Serializes a wide string (STANDARD.md "wstring"): the length in UTF-16
  code units as `serialize_int(length, 0, buffer_size - 1)`, then each code
  unit as a 32-bit group — no alignment anywhere in the operation. An
  astral code point travels as its surrogate pair. The reader refuses a
  group above 0xFFFF, an interior NUL group and any unpaired surrogate.
  """
  @spec serialize_wstring(stream, String.t() | nil, pos_integer) :: result(String.t())
  def serialize_wstring(stream, value, buffer_size)
      when is_integer(buffer_size) and buffer_size >= 1 and buffer_size <= @int32_max do
    units =
      if writing?(stream) do
        unless is_binary(value) do
          raise ArgumentError, "serialize_wstring value must be a string"
        end

        units = utf16_units(value)

        unless length(units) < buffer_size do
          raise ArgumentError, "serialize_wstring value does not fit buffer_size #{buffer_size}"
        end

        units
      else
        []
      end

    with {:ok, stream, length} <- serialize_int(stream, length(units), 0, buffer_size - 1) do
      if reading?(stream) do
        read_wstring(stream, length, nil, [])
      else
        case write_wstring_units(stream, units) do
          {:ok, stream} -> {:ok, stream, value}
          error -> error
        end
      end
    end
  end

  defp utf16_units(value) do
    encoded = :unicode.characters_to_binary(value, :utf8, {:utf16, :little})

    unless is_binary(encoded) do
      raise ArgumentError, "serialize_wstring value is not valid UTF-8"
    end

    for <<unit::little-16 <- encoded>>, do: unit
  end

  defp write_wstring_units(stream, []), do: {:ok, stream}

  defp write_wstring_units(stream, [unit | rest]) do
    with {:ok, stream, _unit} <- serialize_bits(stream, unit, 32) do
      write_wstring_units(stream, rest)
    end
  end

  # The read loop, refusal for refusal the reference's: a group above
  # 0xFFFF is not a UTF-16 code unit; a zero group is the two-lengths
  # smuggling primitive; a high surrogate demands its low, a low demands a
  # preceding high, and a dangling high as the final group fails. Pairs
  # recombine into the code point at the boundary.
  defp read_wstring(stream, 0, nil, acc) do
    {:ok, stream, acc |> Enum.reverse() |> List.to_string()}
  end

  defp read_wstring(stream, 0, _pending, _acc), do: refuse(stream)

  defp read_wstring(stream, remaining, pending, acc) do
    with {:ok, stream, unit} <- serialize_bits(stream, 0, 32) do
      cond do
        unit > 0xFFFF ->
          refuse(stream)

        unit == 0 ->
          refuse(stream)

        pending != nil ->
          if unit >= 0xDC00 and unit <= 0xDFFF do
            code_point = 0x10000 + ((pending - 0xD800) <<< 10) + (unit - 0xDC00)
            read_wstring(stream, remaining - 1, nil, [code_point | acc])
          else
            refuse(stream)
          end

        unit >= 0xDC00 and unit <= 0xDFFF ->
          refuse(stream)

        unit >= 0xD800 and unit <= 0xDBFF ->
          read_wstring(stream, remaining - 1, unit, acc)

        true ->
          read_wstring(stream, remaining - 1, nil, [unit | acc])
      end
    end
  end

  # ------------------------------------------------------------------
  # stream accessors
  # ------------------------------------------------------------------

  @doc "The number of bits processed so far."
  @spec bits_processed(stream) :: non_neg_integer
  def bits_processed(stream), do: smod(stream).bits_processed(stream)

  @doc "The number of bytes processed so far: the bit count rounded up."
  @spec bytes_processed(stream) :: non_neg_integer
  def bytes_processed(stream), do: smod(stream).bytes_processed(stream)

  @doc "The pad bits an align would cost now: exact on write and read, 7 on measure."
  @spec align_bits(stream) :: 0..7
  def align_bits(stream), do: smod(stream).align_bits(stream)

  # ------------------------------------------------------------------
  # shared group codec and dispatch
  # ------------------------------------------------------------------

  # 32-bit groups from least significant upward, the final group carrying
  # the remainder: the shared splitting rule of serialize_bits, the wide
  # fixed point path and the ranged 128-bit integer.
  defp serialize_groups(stream, offset, bits), do: serialize_groups(stream, offset, bits, 0, 0)

  defp serialize_groups(stream, offset, bits, shift, acc) when bits <= 32 do
    group = if writing?(stream), do: offset >>> shift &&& Bits.mask(bits), else: 0

    with {:ok, stream, group} <- serialize_bits(stream, group, bits) do
      {:ok, stream, if(reading?(stream), do: acc ||| group <<< shift, else: offset)}
    end
  end

  defp serialize_groups(stream, offset, bits, shift, acc) do
    group = if writing?(stream), do: offset >>> shift &&& 0xFFFFFFFF, else: 0

    with {:ok, stream, group} <- serialize_bits(stream, group, 32) do
      serialize_groups(stream, offset, bits - 32, shift + 32, acc ||| group <<< shift)
    end
  end

  # The hot per-field operations (bits, int, bytes, align) dispatch on
  # function heads above -- a pattern match into a direct call. The wider
  # and accessor operations route through this module table: one dynamic
  # call per whole operation, off the per-bit-group path.
  defp smod(%WriteStream{}), do: WriteStream
  defp smod(%ReadStream{}), do: ReadStream
  defp smod(%MeasureStream{}), do: MeasureStream

  # A refusal decided above the stream primitives — an out-of-range
  # compressed float or fixed offset, a malformed string or wide string, an
  # int_relative reconstruction outside the domain. Failure is terminal, so
  # the refusal latches the stream the way the primitives' own do. The
  # ReadStream pattern is load bearing: a refusal can only be decided while
  # reading, and a miss crashes here rather than skipping the latch.
  defp refuse(%ReadStream{} = stream), do: {:error, ReadStream.fail(stream)}

  defp writing?(%ReadStream{}), do: false
  defp writing?(_stream), do: true

  defp reading?(%ReadStream{}), do: true
  defp reading?(_stream), do: false
end
