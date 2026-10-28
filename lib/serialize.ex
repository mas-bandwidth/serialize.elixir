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
    * `{:ok, stream}` — for `serialize_align/1` and `serialize_end/1`;
    * `{:error, stream}` — a read refusal, the reference's `false` return;
      `refusal/1` names the rule that refused it.

  Writes assume trusted data. Write misuse — a value outside its range or
  width, a float not finite in float32, a bad declaration, text that is not
  UTF-8, holds a zero byte or does not fit, `serialize_reject/1` on a
  write — raises `ArgumentError` at the call. That is this implementation's
  trap (IMPLEMENTING.md U9): Elixir has no unchecked build, so it traps in
  every run, on the write and the measure stream alike (U6). Write misuse
  never latches: a write or measure stream has no refusal state, and the
  reader's reasons are never recorded there. `serialize_fail/2` on a write
  or measure returns `{:error, stream}`, records nothing, and never raises.
  Reads validate always — hostile bytes refuse as values and never raise
  (U7).

  A refusal hands back no value at all: `{:error, stream}` has no third
  element, so nothing can be mistaken for a decoded value. It is also
  terminal — nothing after the failing operation has a defined position —
  and the stream enforces that: the refusal latches the read stream
  failed, and every later read on it refuses without consuming bits. See
  `Serialize.ReadStream`.

  Every refusal names its rule from STANDARD.md's closed list — `:past_end`,
  `:value_out_of_range`, `:nonzero_padding`, `:trailing_data`,
  `:non_finite_float`, `:invalid_utf8`, `:embedded_nul`, `:non_canonical`
  and `:rejected` — and the stream keeps the first one: `refusal/1` reads
  it. `:rejected` is the caller's own refusal, made with
  `serialize_reject/1`.

  Compose messages with `serialize_object/2`, which calls a nested
  object's serialize function inline and contributes no bytes; it keeps a
  failed stream terminal and latches `:rejected` when the nested function
  refuses on its own. A packet reader ends the top-level object with
  `serialize_end/1`, which refuses trailing bytes and set padding, so one
  value has exactly one byte sequence.

  The wire carries finite floats only, and BEAM float terms are always
  finite: `serialize_float/2` and `serialize_double/2` take and return plain
  floats, and a reader refuses a NaN or infinity pattern as
  `:non_finite_float`. See `Serialize.Float32`.
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
    check_wide_bits!(value, bits)
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
    check_wide_bits!(value, bits)
    {:ok, stream, _} = MeasureStream.serialize_bits(stream, 0, 32)
    {:ok, stream, _} = MeasureStream.serialize_bits(stream, 0, bits - 32)
    {:ok, stream, value}
  end

  # a bit count outside [1, 64] is a bad declaration (IMPLEMENTING.md U16)
  def serialize_bits(stream, _value, bits),
    do: misuse(stream, "serialize_bits bits must be an integer in [1, 64], got #{inspect(bits)}")

  # The write and measure check of a value wider than 32 bits (U6, U8): the
  # value is checked as the caller passed it, before it is split into groups.
  defp check_wide_bits!(value, bits) do
    unless is_integer(value) and value >= 0 and value <= Bits.mask(bits) do
      raise ArgumentError, "serialize_bits value #{inspect(value)} does not fit #{bits} bits"
    end
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

  # bounds outside int32, or min above max (U5, U16)
  def serialize_int(stream, _value, min, max),
    do:
      misuse(
        stream,
        "serialize_int bounds must be int32 with min <= max, got [#{inspect(min)}, #{inspect(max)}]"
      )

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

  def serialize_int64(stream, _value, min, max),
    do:
      misuse(
        stream,
        "serialize_int64 bounds must be int64 with min <= max, got [#{inspect(min)}, #{inspect(max)}]"
      )

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

  def serialize_int128(stream, _value, min, max),
    do:
      misuse(
        stream,
        "serialize_int128 bounds must be int128 with min <= max, got [#{inspect(min)}, #{inspect(max)}]"
      )

  # ------------------------------------------------------------------
  # floating point
  # ------------------------------------------------------------------

  @doc """
  Serializes the 32 bits of an IEEE-754 single-precision value as one
  32-bit group. Finite values only, each one bit exact, -0.0 and the
  subnormals included: the reader tests the raw bits and refuses NaN and
  the infinities as `:non_finite_float`, and a writer handed a double that
  narrows past float32 raises.
  """
  @spec serialize_float(stream, Float32.value()) :: result(Float32.value())
  def serialize_float(%ReadStream{} = stream, _value) do
    with {:ok, stream, pattern} <- ReadStream.serialize_bits(stream, 0, 32) do
      if not Float32.finite32?(pattern) do
        refuse(stream, :non_finite_float)
      else
        {:ok, stream, Float32.value32(pattern)}
      end
    end
  end

  def serialize_float(_stream, value) when not is_float(value),
    do: raise(ArgumentError, "serialize_float value must be a float, got #{inspect(value)}")

  def serialize_float(stream, value) do
    {:ok, stream, _pattern} = serialize_bits(stream, Float32.bits32(value), 32)
    {:ok, stream, value}
  end

  @doc """
  Serializes the 64 bits of an IEEE-754 double-precision value as one
  64-bit group, low 32 bits first. Finite values only, each one bit exact:
  the reader tests the raw bits and refuses NaN and the infinities as
  `:non_finite_float`.
  """
  @spec serialize_double(stream, Float32.value()) :: result(Float32.value())
  def serialize_double(%ReadStream{} = stream, _value) do
    with {:ok, stream, pattern} <- serialize_bits(stream, 0, 64) do
      if not Float32.finite64?(pattern) do
        refuse(stream, :non_finite_float)
      else
        {:ok, stream, Float32.value64(pattern)}
      end
    end
  end

  def serialize_double(_stream, value) when not is_float(value),
    do: raise(ArgumentError, "serialize_double value must be a float, got #{inspect(value)}")

  def serialize_double(stream, value) do
    {:ok, stream, _pattern} = serialize_bits(stream, Float32.bits64(value), 64)
    {:ok, stream, value}
  end

  @doc """
  Serializes a float quantized to a resolution over `[min, max]`
  (STANDARD.md "compressed_float"). The quantization arithmetic is float32
  with two roundings on each side, emulated exactly; the declaration must
  be finite in float32, top decode (`min + delta`) included, and a value
  that is not finite in float32 — a double past FLT_MAX, or an integer too
  large for a double — is write misuse: both raise `ArgumentError` on write
  and measure, and such a value is never clamped (IMPLEMENTING.md U9). A
  finite value outside `[min, max]` clamps into it. The
  reader refuses an integer above the step count as `:value_out_of_range`
  and a decode that is not finite as `:non_finite_float`, whatever the
  declaration. Lossy by construction: a round trip returns the nearest
  representable quantum.

  A declaration that is not a number, not finite in float32, or not
  `min < max` and `res > 0` refuses on read as `:value_out_of_range` before
  any bits move (IMPLEMENTING.md U16), and raises `ArgumentError` on write
  and measure. The derivation is `compressed_float_params/3`, and
  `serialize_compressed_float_precomputed/6` takes its constants.
  """
  @spec serialize_compressed_float(stream, number, number, number, number) :: result(float)
  def serialize_compressed_float(stream, value, min, max, res) do
    with {:ok, {miv, bits, delta}} <- compressed_float_params(min, max, res),
         {:ok, min32} <- declaration32(min, "min") do
      compressed_float(stream, value, miv, bits, delta, min32)
    else
      {:error, message} -> misuse(stream, message)
    end
  end

  @doc """
  Derives the compressed float wire constants from a `(min, max, res)`
  declaration (the reference's `serialize_compressed_float_params`):
  `{:ok, {max_integer_value, bits, delta}}`, where `max_integer_value` is the
  step count `ceil((max - min) / res)` clamped to `[1, 4294967040]`, `bits`
  is `bits_required(0, max_integer_value)`, and `delta` is `max - min`
  rounded to float32. The constants depend only on the declaration, so a
  caller or a schema compiler derives them once and passes them to
  `serialize_compressed_float_precomputed/6` at every call.

  A declaration that is not a number, not finite in float32, or not
  `min < max` and `res > 0` is `{:error, message}`: it never raises.
  """
  @spec compressed_float_params(number, number, number) ::
          {:ok, {pos_integer, 1..32, float}} | {:error, String.t()}
  def compressed_float_params(min, max, res) do
    with {:ok, min32} <- declaration32(min, "min"),
         {:ok, max32} <- declaration32(max, "max"),
         {:ok, res32} <- declaration32(res, "res"),
         :ok <- ordered(min32 < max32 and res32 > 0),
         {:ok, delta} <- declaration32(max32 - min32, "delta"),
         {:ok, values} <- declaration32(delta / res32, "delta / res") do
      values =
        cond do
          values < 1.0 -> 1.0
          # largest float32 below 2^32
          values > 4_294_967_040.0 -> 4_294_967_040.0
          true -> values
        end

      max_integer_value = trunc(Float.ceil(values))
      {:ok, {max_integer_value, Bits.bits_required(0, max_integer_value), delta}}
    end
  end

  @doc """
  Serializes a compressed float from precomputed wire constants (the
  reference's `serialize_compressed_float_precomputed`): the constants are
  exactly what `compressed_float_params/3` derives from a declaration, and
  the bytes are identical to `serialize_compressed_float/5` over that
  declaration.

  Constants that cannot have been derived — `max_integer_value` outside
  `[1, 4294967040]`, `bits` other than `bits_required(0,
  max_integer_value)`, a `delta` that is not positive and finite in float32,
  or a `min` that is not finite in float32 — raise on write and measure and
  refuse as `:value_out_of_range` on read, before any bits move
  (IMPLEMENTING.md U16).
  """
  @spec serialize_compressed_float_precomputed(stream, number, pos_integer, 1..32, number, number) ::
          result(float)
  def serialize_compressed_float_precomputed(stream, value, miv, bits, delta, min) do
    with :ok <- precomputed_constants(miv, bits),
         {:ok, delta32} <- declaration32(delta, "delta"),
         :ok <- positive_delta(delta32),
         {:ok, min32} <- declaration32(min, "min") do
      compressed_float(stream, value, miv, bits, delta32, min32)
    else
      {:error, message} -> misuse(stream, message)
    end
  end

  defp precomputed_constants(miv, bits)
       when is_integer(miv) and miv >= 1 and miv <= 4_294_967_040 and is_integer(bits) do
    if bits == Bits.bits_required(0, miv),
      do: :ok,
      else:
        {:error, "serialize_compressed_float bits must be bits_required(0, max_integer_value)"}
  end

  defp precomputed_constants(_miv, _bits),
    do:
      {:error,
       "serialize_compressed_float max_integer_value must be an integer in [1, 4294967040]"}

  defp positive_delta(delta) when delta > 0.0, do: :ok
  defp positive_delta(_delta), do: {:error, "serialize_compressed_float delta must be positive"}

  defp ordered(true), do: :ok
  defp ordered(false), do: {:error, "serialize_compressed_float requires min < max and res > 0"}

  # A declaration parameter as a float32-rounded double, or an error: never
  # an exception, whatever the caller passed (U7, U16).
  defp declaration32(value, name) do
    with {:ok, float} <- to_double(value),
         rounded when is_float(rounded) <- Float32.round32(float) do
      {:ok, rounded}
    else
      _ -> {:error, "serialize_compressed_float #{name} must be a number finite in float32"}
    end
  end

  # A number as a double. An integer too large for a double is :error,
  # never the ArithmeticError the conversion raises.
  defp to_double(value) when is_float(value), do: {:ok, value}

  defp to_double(value) when is_integer(value) do
    {:ok, value * 1.0}
  rescue
    ArithmeticError -> :error
  end

  defp to_double(_value), do: :error

  # The one body behind both entry points, over validated constants.
  defp compressed_float(stream, value, miv, bits, delta, min32) do
    integer_value =
      if writing?(stream) do
        value32 = compressed_float_value32(value)

        # the declaration's top decode must be finite: checked where the
        # declaration is used to write, never on read, where the decode
        # refuses instead
        unless is_float(compressed_float_decode(miv, miv, delta, min32)) do
          raise ArgumentError,
                "serialize_compressed_float declaration decodes its top integer to an infinity"
        end

        compressed_float_quantize(value32, min32, delta, miv)
      else
        0
      end

    with {:ok, stream, integer_value} <- serialize_bits(stream, integer_value, bits) do
      cond do
        not reading?(stream) ->
          {:ok, stream, value}

        integer_value > miv ->
          refuse(stream, :value_out_of_range)

        true ->
          read_compressed_float(stream, compressed_float_decode(integer_value, miv, delta, min32))
      end
    end
  end

  # every operand is finite and the integer is in range, and still the
  # final add can round past FLT_MAX: a non-finite decode is refused
  defp read_compressed_float(stream, decoded) when not is_float(decoded),
    do: refuse(stream, :non_finite_float)

  defp read_compressed_float(stream, decoded), do: {:ok, stream, decoded}

  # The caller's value narrowed to float32, as the reference's float
  # parameter narrows it. A value whose float32 form is not finite is write
  # misuse and raises (U9): the reference asserts a non-finite value, and
  # only its unchecked build clamps one.
  defp compressed_float_value32(value) do
    with {:ok, float} <- to_double(value),
         value32 when is_float(value32) <- Float32.round32(float) do
      value32
    else
      _ -> raise ArgumentError, "serialize_compressed_float value must be finite in float32"
    end
  end

  # The writer's quantization, exactly the reference's float32 steps: the
  # normalized value clamps to [0,1], the product rounds to float32 BEFORE
  # 0.5 is added, that sum rounds before the floor, and the floored integer
  # clamps to the step count (the normative integer clamp, STANDARD.md
  # 2026-08-23). The value is already float32 and finite; the difference
  # from min can still overflow float32, and clamps as the reference's
  # infinity does.
  defp compressed_float_quantize(value32, min32, delta, miv) do
    normalized =
      case Float32.round32(value32 - min32) do
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

    # the final add can round past FLT_MAX for a non-conforming
    # declaration: an infinity comes back as :pos_inf or :neg_inf, never
    # raised, and the caller refuses it
    Float32.round32(scaled + min32)
  end

  # ------------------------------------------------------------------
  # int_relative
  # ------------------------------------------------------------------

  # the flag ladder's payload tiers: {min, max} of serialize_int per tier
  @relative_tiers [{2, 6}, {7, 23}, {24, 280}, {281, 4377}, {4378, 69_914}]

  # the int_relative domain: 0 to 2^31 - 1 inclusive, a property of the
  # operation rather than of the caller's storage type
  @relative_max 0x7FFFFFFF

  # the largest difference a bounded tier carries: the absolute tier holding
  # a difference this small is a second encoding of the value
  @relative_bounded_max 69_914

  @doc """
  Serializes `current` relative to `previous`, where `current > previous`
  (STANDARD.md "int_relative"): a ladder of one-bit flags with a payload
  sized to the difference, and `current` itself as 32 raw bits at the final
  tier.

  The domain is `0` to `2^31 - 1` inclusive, and both `previous` and
  `current` lie in it. `previous` is caller state and never arrives off the
  wire, so one outside the domain is caller error: it raises on write and
  measure and refuses as `:value_out_of_range` on read.
  The reader reconstructs `current` on BEAM integers, which cannot wrap at
  any width, then refuses the read as `:value_out_of_range` unless the
  result lies in the domain and is strictly greater than `previous` — in
  the one-bit tier, in each of the five bounded tiers, and in the absolute
  tier alike. Positive only, strictly increasing, no wrapping. The absolute
  tier is canonical too: carrying a difference of 69914 or less, which a
  bounded tier would have taken, it is refused as `:non_canonical`, after
  the domain rule.
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
        relative_result(stream, previous, previous + 1, current, :bounded)
      else
        relative_tiers(stream, previous, current, difference, @relative_tiers)
      end
    end
  end

  # `previous` outside the domain is a bad declaration (U7, U16)
  def serialize_int_relative(stream, previous, _current),
    do:
      misuse(
        stream,
        "serialize_int_relative previous must be in [0, 2^31-1], got #{inspect(previous)}"
      )

  defp relative_tiers(stream, previous, current, difference, [{lo, hi} | rest]) do
    with {:ok, stream, flag} <- serialize_bool(stream, writing?(stream) and difference <= hi) do
      if flag do
        payload = if writing?(stream), do: difference, else: lo

        with {:ok, stream, d} <- serialize_int(stream, payload, lo, hi) do
          relative_result(stream, previous, previous + d, current, :bounded)
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
      relative_result(stream, previous, value, current, :absolute)
    end
  end

  # The reconstruction check every tier owes: `reconstructed` is computed on
  # arbitrary precision BEAM integers, so it cannot wrap, and the read is
  # refused unless it lies in the domain and above `previous`. Then the
  # absolute tier's canonical rule: the domain comes first, so a value
  # outside it is out of range whatever its difference.
  defp relative_result(stream, previous, reconstructed, current, tier) do
    cond do
      not reading?(stream) ->
        {:ok, stream, current}

      reconstructed > @relative_max ->
        refuse(stream, :value_out_of_range)

      reconstructed <= previous ->
        refuse(stream, :value_out_of_range)

      tier == :absolute and reconstructed - previous <= @relative_bounded_max ->
        refuse(stream, :non_canonical)

      true ->
        {:ok, stream, reconstructed}
    end
  end

  # ------------------------------------------------------------------
  # fixed point
  # ------------------------------------------------------------------

  @doc """
  Serializes a fixed point value (STANDARD.md "fixed"): `value` is the raw
  scaled integer of a Q format `integer_bits.fraction_bits`, and `min` and
  `max` are bounds in whole units. The raw value is a ranged integer over
  the raw bounds `min <<< fraction_bits` and `max <<< fraction_bits`, so
  the operation IS `serialize_int128/4` over those bounds and shares its
  codec: the offset in exactly the bit length of the raw range, split into
  32-bit groups from least significant upward, a degenerate range where
  `min == max` costing zero bits on every storage width, and a decoded
  offset above the raw range refused. The round trip is exact. A raw value
  outside the raw bounds is caller error and raises.
  """
  @spec serialize_fixed(stream, integer, pos_integer, non_neg_integer, integer, integer) ::
          result(integer)
  def serialize_fixed(stream, value, integer_bits, fraction_bits, min, max) do
    case fixed_params(integer_bits, fraction_bits, min, max) do
      {:ok, raw_min, raw_max} ->
        smod(stream).serialize_integer128(stream, value, raw_min, raw_max)

      {:error, message} ->
        misuse(stream, message)
    end
  end

  # The declaration arithmetic: the Q format must fill one of the storage
  # widths, the bounds must be int64 whole units that fit the format's
  # capacity — signed when min is negative, with the sign bit counting
  # toward integer_bits — and the raw bounds are the whole-unit bounds
  # scaled. All one lane: BEAM integers cover every storage width.
  # A declaration that does not hold is returned, never raised: the caller
  # raises on write and measure and refuses on read (U16).
  defp fixed_params(integer_bits, fraction_bits, min, max) do
    cond do
      not (is_integer(integer_bits) and integer_bits >= 1 and is_integer(fraction_bits) and
             fraction_bits >= 0 and (integer_bits + fraction_bits) in [8, 16, 32, 64, 128]) ->
        {:error,
         "serialize_fixed integer_bits + fraction_bits must equal a storage width (8/16/32/64/128)"}

      not (is_integer(min) and is_integer(max) and min >= @int64_min and max <= @int64_max and
               min <= max) ->
        {:error, "serialize_fixed bounds must be int64 whole units with min <= max"}

      not fixed_capacity_ok?(integer_bits, min, max) ->
        {:error, "serialize_fixed bounds in whole units do not fit the Q format"}

      true ->
        {:ok, min <<< fraction_bits, max <<< fraction_bits}
    end
  end

  defp fixed_capacity_ok?(integer_bits, min, max) when min < 0 do
    (integer_bits >= 65 or min >= -(1 <<< (integer_bits - 1))) and
      (integer_bits >= 64 or max <= (1 <<< (integer_bits - 1)) - 1)
  end

  defp fixed_capacity_ok?(integer_bits, _min, max),
    do: integer_bits >= 64 or max <= (1 <<< integer_bits) - 1

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
  def serialize_bytes(%WriteStream{} = stream, data, count)
      when is_integer(count) and count >= 0 do
    WriteStream.serialize_bytes(stream, data, count)
  end

  def serialize_bytes(%ReadStream{} = stream, data, count) when is_integer(count) do
    ReadStream.serialize_bytes(stream, data, count)
  end

  def serialize_bytes(%MeasureStream{} = stream, data, count)
      when is_integer(count) and count >= 0 do
    MeasureStream.serialize_bytes(stream, data, count)
  end

  # a count that is not a non-negative integer (U7, U16)
  def serialize_bytes(stream, _data, count),
    do:
      misuse(
        stream,
        "serialize_bytes count must be a non-negative integer, got #{inspect(count)}"
      )

  @doc """
  Serializes a UTF-8 string (STANDARD.md "string"): the length as
  `serialize_int(length, 0, buffer_size - 1)`, then the bytes via the
  aligning bytes operation. The payload is well-formed UTF-8 with no
  interior NUL by writer contract, checked on write and measure with the
  rest of the writer's contract (IMPLEMENTING.md U4) — and the reader
  refuses a payload violating either rule:
  a length past the buffer as `:value_out_of_range`, a zero byte as
  `:embedded_nul`, then malformed UTF-8 as `:invalid_utf8`. An accepted
  payload comes back exactly as read: no normalization, no replacement and
  no stripped byte order mark.
  """
  @spec serialize_string(stream, String.t() | nil, pos_integer) :: result(String.t())
  def serialize_string(stream, value, buffer_size)
      when is_integer(buffer_size) and buffer_size >= 1 and buffer_size <= @int32_max do
    length =
      if writing?(stream) do
        unless is_binary(value) and byte_size(value) < buffer_size do
          raise ArgumentError, "serialize_string value must be a binary shorter than buffer_size"
        end

        # U3 and U4: the writer sends only what every reader accepts
        unless :binary.match(value, <<0>>) == :nomatch and String.valid?(value) do
          raise ArgumentError, "serialize_string value must be UTF-8 with no zero byte"
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
          :binary.match(payload, <<0>>) != :nomatch -> refuse(stream, :embedded_nul)
          not String.valid?(payload) -> refuse(stream, :invalid_utf8)
          true -> {:ok, stream, payload}
        end
      else
        {:ok, stream, value}
      end
    end
  end

  # a buffer_size below 1 or past int32 (U7, U16)
  def serialize_string(stream, _value, buffer_size),
    do:
      misuse(
        stream,
        "serialize_string buffer_size must be an integer in [1, 2^31-1], got #{inspect(buffer_size)}"
      )

  @doc """
  Bounds a string for a `serialize_string/3` buffer (the reference's
  `serialize_copy_string`, IMPLEMENTING.md U15): returns the bytes of
  `source` before its first zero byte, and if there are more than
  `dest_size - 1` of them, the first `dest_size - 1`, then drops bytes from
  the end while the first byte left out is a UTF-8 continuation byte
  (`10xxxxxx`). For well-formed UTF-8 that is the longest prefix that fits
  and does not end inside a character, so `serialize_string/3` with
  `buffer_size = dest_size` accepts it.

  Elixir strings are values, so the helper returns the prefix rather than
  filling a buffer. It works on any binary, by the byte rule above.
  A `dest_size` below 1 or not an integer, or a `source` that is not a
  binary, is write misuse and raises `ArgumentError` (U9).

      iex> Serialize.serialize_copy_string("héllo", 3)
      "h"
  """
  @spec serialize_copy_string(binary, pos_integer) :: binary
  def serialize_copy_string(source, dest_size)
      when is_binary(source) and is_integer(dest_size) and dest_size >= 1 do
    prefix =
      case :binary.match(source, <<0>>) do
        {at, 1} -> binary_part(source, 0, at)
        :nomatch -> source
      end

    if byte_size(prefix) <= dest_size - 1 do
      prefix
    else
      binary_part(prefix, 0, whole_character_cut(prefix, dest_size - 1))
    end
  end

  def serialize_copy_string(source, dest_size) do
    raise ArgumentError,
          "serialize_copy_string needs a binary source and an integer dest_size >= 1, " <>
            "got #{inspect(source)}, #{inspect(dest_size)}"
  end

  # Backs a cut off while the first byte left out is a continuation byte.
  defp whole_character_cut(_prefix, 0), do: 0

  defp whole_character_cut(prefix, cut) do
    if (:binary.at(prefix, cut) &&& 0xC0) == 0x80,
      do: whole_character_cut(prefix, cut - 1),
      else: cut
  end

  # ------------------------------------------------------------------
  # end
  # ------------------------------------------------------------------

  @doc """
  Serializes the end of the object (STANDARD.md "end"): a packet reader
  calls it after the last field of the top-level object. A writer's end
  emits nothing and a measure's costs nothing. A reader's end refuses a
  whole byte or more after the object as `:trailing_data` — checked first —
  and a set bit among the final byte's unused bits as `:nonzero_padding`,
  then consumes that padding, so an accepted end leaves the stream exactly
  consumed. On a failed stream it refuses with the first refusal's reason.
  """
  @spec serialize_end(stream) :: {:ok, stream} | {:error, stream}
  def serialize_end(%WriteStream{} = stream), do: WriteStream.serialize_end(stream)
  def serialize_end(%ReadStream{} = stream), do: ReadStream.serialize_end(stream)
  def serialize_end(%MeasureStream{} = stream), do: MeasureStream.serialize_end(stream)

  # ------------------------------------------------------------------
  # the caller's refusal, and object composition
  # ------------------------------------------------------------------

  @doc """
  The caller's own refusal (STANDARD.md "Refusal reasons", `rejected`): the
  bytes were well formed, every primitive accepted them, and the caller's
  own validation says no — an enum value the game does not know, two fields
  that contradict each other. On a read stream it latches `:rejected` and
  returns `{:error, stream}`; the refusal is terminal like every other, and
  on a stream that already refused the first reason is kept.

      with {:ok, stream, kind} <- Serialize.serialize_bits(stream, kind, 4) do
        if kind in @known_kinds, do: {:ok, stream, kind}, else: Serialize.serialize_reject(stream)
      end

  Rejecting only means something on read. On a write or measure stream it
  is caller misuse, and raises `ArgumentError`, the trap, in every run:
  this port has no unchecked build (IMPLEMENTING.md U9).
  """
  @spec serialize_reject(stream) :: {:error, stream}
  def serialize_reject(%ReadStream{} = stream), do: {:error, ReadStream.reject(stream)}

  def serialize_reject(stream),
    do: misuse(stream, "serialize_reject on a write or measure stream: reject is read only")

  @doc """
  Serializes a nested object (STANDARD.md "object"): calls `fun` with the
  stream, inline. The object contributes no bytes of its own — no framing,
  length prefix or alignment — so this is composition, and the bytes are
  exactly those `fun` reads or writes.

  `fun` is the object's own serialize function, the same single function
  for writing, reading and measuring. It returns `{:ok, stream}`,
  `{:ok, stream, value}` or `{:error, stream}`, and this returns what it
  returned, with these rules on a read stream:

    * a stream that already refused refuses on entry, with its first
      reason, and `fun` is never called;
    * `fun` returning `{:error, stream}` with nothing latched is the
      caller's refusal, and the stream latches `:rejected`; when a read
      inside `fun` already refused, that first reason is kept;
    * `fun` returning success on a stream that failed inside it refuses
      too, with the reason that failed it.

  So a refused read stream always names a reason, and a nested object's
  `{:error, stream}` and `serialize_reject/1` agree. On a write or measure
  stream `fun`'s result is passed through: an `{:error, stream}` there
  returns the error and records nothing (U9).
  """
  @spec serialize_object(stream, (stream ->
                                    {:ok, stream} | {:ok, stream, value} | {:error, stream})) ::
          {:ok, stream} | {:ok, stream, value} | {:error, stream}
        when value: term
  def serialize_object(%ReadStream{failed: true} = stream, fun) when is_function(fun, 1),
    do: {:error, stream}

  def serialize_object(%ReadStream{} = stream, fun) when is_function(fun, 1) do
    case fun.(stream) do
      {:ok, %ReadStream{failed: false}} = ok -> ok
      {:ok, %ReadStream{failed: false}, _value} = ok -> ok
      {_result, %ReadStream{} = stream} -> {:error, latch_object(stream)}
      {_result, %ReadStream{} = stream, _value} -> {:error, latch_object(stream)}
    end
  end

  def serialize_object(stream, fun) when is_function(fun, 1), do: fun.(stream)

  # The object's latch: through the same latch as every refusal, so a
  # reason already latched inside the object is kept, and an object that
  # refused on its own latches rejected.
  defp latch_object(stream), do: ReadStream.fail(stream, :rejected)

  # ------------------------------------------------------------------
  # stream accessors
  # ------------------------------------------------------------------

  @doc "The number of bits processed so far."
  @spec bits_processed(stream) :: non_neg_integer
  def bits_processed(stream), do: smod(stream).bits_processed(stream)

  @doc "The number of bytes processed so far: the bit count rounded up."
  @spec bytes_processed(stream) :: non_neg_integer
  def bytes_processed(stream), do: smod(stream).bytes_processed(stream)

  @doc """
  The first refusal's reason on a read stream — one of
  `Serialize.ReadStream.refusals/0` — or `nil` while no read has failed.
  """
  @spec refusal(ReadStream.t()) :: ReadStream.refusal() | nil
  def refusal(%ReadStream{} = stream), do: ReadStream.refusal(stream)

  @doc """
  The family spelling of a read stream's refusal (IMPLEMENTING.md U14):
  `"past_end"`, `"value_out_of_range"` and the rest of
  `Serialize.ReadStream.refusals/0` as strings, and `"none"` while no read
  has failed. A refusal reason atom, or `nil`, is accepted too.
  """
  @spec refusal_name(ReadStream.t() | ReadStream.refusal() | nil) :: String.t()
  def refusal_name(%ReadStream{} = stream), do: refusal_name(ReadStream.refusal(stream))
  def refusal_name(nil), do: "none"
  def refusal_name(reason) when is_atom(reason), do: Atom.to_string(reason)

  @doc """
  Fails the stream with a refusal reason (the reference's `serialize_fail`,
  IMPLEMENTING.md U14). On a read stream it latches `reason`, and any value
  outside the closed list — `nil` included — latches `:rejected`, so a
  refused stream never reports none; a stream that already refused keeps
  its first reason. On a write or measure stream it returns
  `{:error, stream}` with the stream unchanged, records nothing, and never
  raises: it is the path every refusal takes, so a serialize function
  shared by the read and write sides can call it (U9).
  """
  @spec serialize_fail(stream, term) :: {:error, stream}
  def serialize_fail(%ReadStream{} = stream, reason),
    do: {:error, ReadStream.fail(stream, reason)}

  def serialize_fail(%WriteStream{} = stream, _reason), do: {:error, stream}
  def serialize_fail(%MeasureStream{} = stream, _reason), do: {:error, stream}

  @doc "The pad bits an align would cost now: exact on write and read, 7 on measure."
  @spec align_bits(stream) :: 0..7
  def align_bits(stream), do: smod(stream).align_bits(stream)

  # ------------------------------------------------------------------
  # stream dispatch
  # ------------------------------------------------------------------

  # The hot per-field operations (bits, int, bytes, align) dispatch on
  # function heads above -- a pattern match into a direct call. The wider
  # and accessor operations route through this module table: one dynamic
  # call per whole operation, off the per-bit-group path.
  defp smod(%WriteStream{}), do: WriteStream
  defp smod(%ReadStream{}), do: ReadStream
  defp smod(%MeasureStream{}), do: MeasureStream

  # A refusal decided above the stream primitives — a non-finite float, an
  # out-of-range or non-finite compressed float, a malformed string, an
  # int_relative reconstruction outside the domain or in a non-canonical
  # tier. Failure is terminal, so the refusal latches the stream, with its
  # reason, the way the primitives' own do. The ReadStream pattern is load
  # bearing: a refusal can only be decided while reading, and a miss crashes
  # here rather than skipping the latch.
  defp refuse(%ReadStream{} = stream, reason), do: {:error, ReadStream.fail(stream, reason)}

  # A caller declaration that does not hold (IMPLEMENTING.md U7, U9, U16):
  # the write-misuse mechanism, ArgumentError, on write and measure; on read
  # a refusal as :value_out_of_range before any bits move. A stream that
  # already refused keeps its first reason.
  defp misuse(%ReadStream{} = stream, _message), do: refuse(stream, :value_out_of_range)
  defp misuse(_stream, message), do: raise(ArgumentError, message)

  defp writing?(%ReadStream{}), do: false
  defp writing?(_stream), do: true

  defp reading?(%ReadStream{}), do: true
  defp reading?(_stream), do: false
end
