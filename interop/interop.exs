defmodule Serialize.Interop do
  @moduledoc """
  The Elixir half of the cross language interop harness.

  Its twin is `interop/interop.cpp`, built in CI against the real C++ serialize
  library at the release `.github/workflows/ci.yml` pins. The two halves run head
  to head on every push and pull request: each writes the boundary message, the
  two files must be byte identical, and each must decode the other's file to the
  exact values and re-encode it to the exact bytes.

      mix run interop/interop.exs write  <file>
      mix run interop/interop.exs read   <file>
      mix run interop/interop.exs refuse <file>

  THE MESSAGE is the boundary set: every operation STANDARD.md defines, at the
  values where implementations disagree. Zero bit ranges on all three ranged
  widths and on fixed point; the domain edges of int, int64, int128 and
  int_relative; the maximum widths of bits, uint128 and the four group fixed
  point path; both sides of the alignment rule, including the align inside a zero
  length bytes; empty and full strings; and the wide string cases the surrogate
  rule governs, up to the largest code unit.

  WHAT IT DELIBERATELY DOES NOT CARRY: a NaN payload. STANDARD.md's bit
  transparency claim covers it, but a NaN's payload bits do not survive every
  language's float type on the way to the wire, so a difference here would say
  nothing about the wire format. This port pins its own NaN patterns in its own
  suite, where the claim can be tested honestly.

  The sequence is one ordered list of steps. Each step carries the value the
  write side sends, the operation, and how a decoded value is compared; the read
  side ignores the value it is handed, so one list serves write, read, expectation
  and re-encode. Any change to it must be mirrored in `interop/interop.cpp`, and
  never changes the wire format.
  """

  import Bitwise

  alias Serialize.Float32
  alias Serialize.ReadStream
  alias Serialize.WriteStream

  @int32_min -2_147_483_648
  @int32_max 2_147_483_647
  @int64_min -(1 <<< 63)
  @int64_max (1 <<< 63) - 1
  @int128_min -(1 <<< 127)
  @int128_max (1 <<< 127) - 1

  # raw bit groups, every width boundary: {width, value}
  @bits_vectors [
    # the minimum width, at its maximum value
    {1, 1},
    # and at its minimum
    {1, 0},
    # a sub-byte width, all ones
    {7, 0x7F},
    # one below the single group maximum
    {31, 0x7FFFFFFF},
    # the widest single group, all ones
    {32, 0xFFFFFFFF},
    # and all zeros
    {32, 0},
    # the first width past the 32 bit split
    {33, 0x1FFFFFFFF},
    # the maximum width, all ones
    {64, 0xFFFFFFFFFFFFFFFF},
    # and all zeros
    {64, 0}
  ]

  @uint8_values [0x00, 0xFF]
  @uint16_values [0x0000, 0xFFFF]
  @uint32_values [0x00000000, 0xFFFFFFFF]
  @uint64_values [0, 0xFFFFFFFFFFFFFFFF]
  @uint128_values [
    0,
    (1 <<< 128) - 1,
    0x0123456789ABCDEF <<< 64 ||| 0x0FEDCBA987654321
  ]

  # ranged 32 bit integers: {min, max, value}
  @int_vectors [
    # degenerate: zero bits, mid sequence
    {42, 42, 42},
    # the bottom of the range
    {-100, 100, -100},
    # the top of the range
    {-100, 100, 100},
    # the full domain, 32 bits on the wire
    {@int32_min, @int32_max, @int32_min},
    {@int32_min, @int32_max, @int32_max},
    # a live field after the degenerate one
    {-100, 100, -37}
  ]

  @int64_vectors [
    # degenerate, with bounds past 2^32
    {10_000_000_000, 10_000_000_000, 10_000_000_000},
    # a range wider than 32 bits, bottom
    {-5_000_000_000, 5_000_000_000, -5_000_000_000},
    # and top
    {-5_000_000_000, 5_000_000_000, 5_000_000_000},
    # the full domain, 64 bits on the wire
    {@int64_min, @int64_max, @int64_min},
    {@int64_min, @int64_max, @int64_max}
  ]

  # 2^100 + 7: a degenerate bound no 64 bit path can carry
  @int128_degenerate (1 <<< 100) + 7

  @int128_vectors [
    {@int128_degenerate, @int128_degenerate, @int128_degenerate},
    # bounds inside the 64 bit domain: the bytes are identical to int64 here
    {-5_000_000_000, 5_000_000_000, 5_000_000_000},
    {@int128_min, @int128_max, @int128_min},
    {@int128_min, @int128_max, @int128_max}
  ]

  # int_relative: every tier at both ends, and the domain edges
  @relative_vectors [
    # one-bit
    {0, 1},
    # bounded-3, both ends
    {0, 2},
    {0, 6},
    # bounded-5
    {0, 7},
    {0, 23},
    # bounded-9
    {0, 24},
    {0, 280},
    # bounded-13
    {0, 281},
    {0, 4377},
    # bounded-17
    {0, 4378},
    {0, 69_914},
    # absolute, at its smallest difference
    {0, 69_915},
    # one-bit, at the top of the domain
    {2_147_483_646, 2_147_483_647},
    # absolute, at the top of the domain
    {0, 2_147_483_647}
  ]

  # floats are given as bit patterns, so no decimal literal is parsed twice
  @float_bits [
    # +0
    0x00000000,
    # -0
    0x80000000,
    # +infinity
    0x7F800000,
    # -infinity
    0xFF800000,
    # the largest finite float32
    0x7F7FFFFF,
    # the smallest normal
    0x00800000,
    # the smallest subnormal
    0x00000001,
    # 1.0
    0x3F800000,
    # -1.0
    0xBF800000
  ]

  @double_bits [
    # +0
    0x0000000000000000,
    # -0
    0x8000000000000000,
    # +infinity
    0x7FF0000000000000,
    # -infinity
    0xFFF0000000000000,
    # the largest finite float64
    0x7FEFFFFFFFFFFFFF,
    # the smallest normal
    0x0010000000000000,
    # the smallest subnormal
    0x0000000000000001,
    # 1.0
    0x3FF0000000000000,
    # -1.0
    0xBFF0000000000000
  ]

  # compressed_float: {value, min, max, resolution}
  @compressed_float_vectors [
    # the bottom of the range: integer 0
    {0.0, 0.0, 10.0, 0.01},
    # the top: the maximum integer
    {10.0, 0.0, 10.0, 0.01},
    # between quanta: 1 under float32, 0 widened
    {0.005, 0.0, 10.0, 0.01},
    # between quanta: 3 vs 2
    {0.025, 0.0, 10.0, 0.01},
    # between quanta: 11 vs 10
    {0.105, 0.0, 10.0, 0.01},
    # between quanta: 1000 vs 999
    {9.995, 0.0, 10.0, 0.01},
    # the bottom of a range with a non-zero min
    {-100.0, -100.0, 100.0, 0.01},
    # off quantum over a non-zero min
    {-42.573, -100.0, 100.0, 0.01},
    # clamp witness A (schema#109)
    {8_388_609.0, 0.0, 8_388_609.0, 1.0},
    # clamp witness B
    {16_777_215.0, 0.0, 16_777_215.0, 1.0},
    # a one bit field, both codes
    {0.0, 0.0, 1.0, 1.0},
    {1.0, 0.0, 1.0, 1.0}
  ]

  # a zero length block first: the align happens anyway
  @bytes_vectors [{0, 0x00}, {8, 0x00}, {8, 0xFF}, {1, 0x5A}]

  @string_buffer_size 16
  @strings [
    # empty
    "",
    # fifteen bytes: the most buffer size 16 carries
    "0123456789abcde",
    # six UTF-8 bytes, as explicit code points so no source file encoding can
    # reach the wire
    "\u{43C}\u{438}\u{440}"
  ]

  @wstring_buffer_size 8
  @wide_strings [
    # empty
    "",
    # basic plane
    "\u{43C}\u{438}\u{440}",
    # the first code unit above the surrogate block
    "\u{E000}",
    # the largest code unit there is
    "\u{FFFF}",
    # U+1F600 as its surrogate pair: four code units
    "A\u{1F600}B",
    # seven code units, the most buffer size 8 carries
    "abcdefg"
  ]

  # --------------------------------------------------------------------------
  # the sequence

  @doc """
  The message as one ordered list of steps: `%{label, value, op, check}`. `op` is
  the operation as `(stream, value) -> {:ok, stream, decoded} | {:error, stream}`,
  and `check` says how a decoded value is compared — `:exact`, `:float32`,
  `:float64`, `{:within, resolution}` for the lossy compressed float, or `:any`
  for the aligns, which decode to nothing.
  """
  def steps do
    List.flatten([
      # raw bit groups
      for {bits, value} <- @bits_vectors do
        step("bits(#{bits})", value, &Serialize.serialize_bits(&1, &2, bits))
      end,
      # bool, both codes
      for value <- [true, false] do
        step("bool", value, &Serialize.serialize_bool/2)
      end,
      # both sides of the alignment rule: the stream is unaligned here, so the
      # first align pads and the second must write nothing at all
      align_step(),
      align_step(),
      # the fixed width unsigned helpers, at their domain edges
      for value <- @uint8_values do
        step("uint8", value, &Serialize.serialize_uint8/2)
      end,
      for value <- @uint16_values do
        step("uint16", value, &Serialize.serialize_uint16/2)
      end,
      for value <- @uint32_values do
        step("uint32", value, &Serialize.serialize_uint32/2)
      end,
      for value <- @uint64_values do
        step("uint64", value, &Serialize.serialize_uint64/2)
      end,
      for value <- @uint128_values do
        step("uint128", value, &Serialize.serialize_uint128/2)
      end,
      # ranged integers
      for {min, max, value} <- @int_vectors do
        step("int(#{min},#{max})", value, &Serialize.serialize_int(&1, &2, min, max))
      end,
      for {min, max, value} <- @int64_vectors do
        step("int64(#{min},#{max})", value, &Serialize.serialize_int64(&1, &2, min, max))
      end,
      for {min, max, value} <- @int128_vectors do
        step("int128", value, &Serialize.serialize_int128(&1, &2, min, max))
      end,
      # fixed point, at the ends of its ranges and degenerate on two storage widths
      align_step(),
      # the bottom and top of a Q8.8 range
      step("fixed q8.8 min", -100 * 256, &Serialize.serialize_fixed(&1, &2, 8, 8, -100, 100)),
      step("fixed q8.8 max", 100 * 256, &Serialize.serialize_fixed(&1, &2, 8, 8, -100, 100)),
      # min == max: zero bits
      step(
        "fixed q16.16 degenerate",
        7 * 65_536,
        &Serialize.serialize_fixed(&1, &2, 16, 16, 7, 7)
      ),
      # 34 bits on the wire
      step(
        "fixed q48.16 min",
        -100_000 * 65_536,
        &Serialize.serialize_fixed(&1, &2, 48, 16, -100_000, 100_000)
      ),
      step(
        "fixed q48.16 max",
        100_000 * 65_536,
        &Serialize.serialize_fixed(&1, &2, 48, 16, -100_000, 100_000)
      ),
      # 75 bits, three groups
      step(
        "fixed q112.16 max",
        144_115_188_075_855_872 <<< 16,
        &Serialize.serialize_fixed(
          &1,
          &2,
          112,
          16,
          -144_115_188_075_855_872,
          144_115_188_075_855_872
        )
      ),
      # zero bits at 128 bit storage
      step("fixed q64.64 degenerate", 5 <<< 64, &Serialize.serialize_fixed(&1, &2, 64, 64, 5, 5)),
      # 128 bits, four groups
      step(
        "fixed q64.64 max",
        @int64_max <<< 64,
        &Serialize.serialize_fixed(&1, &2, 64, 64, @int64_min, @int64_max)
      ),
      # int_relative
      for {previous, current} <- @relative_vectors do
        step(
          "int_relative(#{previous})",
          current,
          &Serialize.serialize_int_relative(&1, previous, &2)
        )
      end,
      # float and double, bit transparent at the domain edges
      for bits <- @float_bits do
        step("float", Float32.value32(bits), &Serialize.serialize_float/2, :float32)
      end,
      for bits <- @double_bits do
        step("double", Float32.value64(bits), &Serialize.serialize_double/2, :float64)
      end,
      # compressed_float
      for {value, min, max, res} <- @compressed_float_vectors do
        step(
          "compressed_float(#{min},#{max},#{res})",
          value,
          &Serialize.serialize_compressed_float(&1, &2, min, max, res),
          {:within, res}
        )
      end,
      # bytes. The three bit filler leaves the stream unaligned, so the align
      # that begins the first block -- a ZERO LENGTH one -- is load bearing.
      step("filler", 5, &Serialize.serialize_bits(&1, &2, 3)),
      for {length, fill} <- @bytes_vectors do
        step(
          "bytes(#{length})",
          :binary.copy(<<fill>>, length),
          &Serialize.serialize_bytes(&1, &2, length)
        )
      end,
      # string: empty, full, and multi-byte UTF-8
      for value <- @strings do
        step("string", value, &Serialize.serialize_string(&1, &2, @string_buffer_size))
      end,
      # wstring: empty, basic plane, the code unit boundaries, a pair, full
      for value <- @wide_strings do
        step("wstring", value, &Serialize.serialize_wstring(&1, &2, @wstring_buffer_size))
      end
    ])
  end

  defp step(label, value, op, check \\ :exact) do
    %{label: label, value: value, op: op, check: check}
  end

  # align returns `{:ok, stream}` and decodes to nothing; it is wrapped so one
  # reduce can drive the whole sequence
  defp align_step do
    op = fn stream, _value ->
      case Serialize.serialize_align(stream) do
        {:ok, stream} -> {:ok, stream, :aligned}
        {:error, stream} -> {:error, stream}
      end
    end

    step("align", :aligned, op, :any)
  end

  @doc """
  Drives the whole sequence over a stream. Read streams ignore the value each
  step carries, so the same list writes, reads and measures the message. Returns
  the decoded value of every step, in order.
  """
  def serialize(stream, steps) do
    result =
      Enum.reduce_while(steps, {:ok, stream, []}, fn step, {:ok, stream, decoded} ->
        case step.op.(stream, step.value) do
          {:ok, stream, value} -> {:cont, {:ok, stream, [value | decoded]}}
          {:error, stream} -> {:halt, {:error, stream}}
        end
      end)

    case result do
      {:ok, stream, decoded} -> {:ok, stream, Enum.reverse(decoded)}
      {:error, stream} -> {:error, stream}
    end
  end

  @doc """
  What a conforming reader recovers. Everything is exact except the compressed
  floats, which are lossy by construction: the reader returns the nearest
  quantum, so they are compared within one resolution step. Floats compare by
  BIT PATTERN — a value comparison cannot see -0.0.
  """
  def problems(steps, decoded) do
    steps
    |> Enum.zip(decoded)
    |> Enum.with_index()
    |> Enum.reject(fn {{step, value}, _index} -> matches?(step, value) end)
    |> Enum.map(fn {{step, value}, index} ->
      "#{index} #{step.label}: got #{inspect(value)}, expected #{inspect(step.value)}"
    end)
  end

  defp matches?(%{check: :any}, _value), do: true
  defp matches?(%{check: :exact} = step, value), do: value === step.value

  defp matches?(%{check: :float32} = step, value),
    do: Float32.bits32(value) == Float32.bits32(step.value)

  defp matches?(%{check: :float64} = step, value),
    do: Float32.bits64(value) == Float32.bits64(step.value)

  defp matches?(%{check: {:within, res}} = step, value) do
    is_number(value) and abs(value - step.value) <= res
  end

  # --------------------------------------------------------------------------
  # the three modes

  defp encode(steps) do
    {:ok, stream, _decoded} = serialize(WriteStream.new(), steps)
    stream |> WriteStream.flush() |> WriteStream.data()
  end

  defp write(path) do
    bytes = encode(steps())
    File.write!(path, bytes)
    IO.puts("interop elixir: wrote #{byte_size(bytes)} bytes to #{path}")
  end

  defp read(path) do
    input = File.read!(path)
    plan = steps()

    case serialize(ReadStream.new(input), plan) do
      {:error, _stream} ->
        die("interop elixir: could not decode #{path}")

      {:ok, _stream, decoded} ->
        case problems(plan, decoded) do
          [] ->
            check_reencode(plan, decoded, input, path)

          list ->
            die(
              "interop elixir: #{path} decoded to unexpected values:\n  " <>
                Enum.join(list, "\n  ")
            )
        end
    end
  end

  # re-encode what was decoded: the bytes must be identical to the input
  defp check_reencode(plan, decoded, input, path) do
    reencoded =
      plan
      |> Enum.zip(decoded)
      |> Enum.map(fn {step, value} -> %{step | value: value} end)
      |> encode()

    if reencoded == input do
      IO.puts(
        "interop elixir: decoded and re-encoded #{byte_size(input)} bytes from #{path}, byte identical"
      )
    else
      die("interop elixir: re-encoded bytes differ from #{path}")
    end
  end

  # The hostile half: every proper prefix of a valid stream is a truncated
  # stream, and a conforming reader refuses every one of them without raising.
  defp refuse(path) do
    input = File.read!(path)
    plan = steps()

    Enum.each(0..(byte_size(input) - 1), fn length ->
      truncated = binary_part(input, 0, length)

      outcome =
        try do
          serialize(ReadStream.new(truncated), plan)
        rescue
          error ->
            die(
              "interop elixir refuse: the #{length} byte prefix of #{path} RAISED: #{inspect(error)}"
            )
        end

      case outcome do
        {:error, _stream} ->
          :ok

        {:ok, _stream, _decoded} ->
          die("interop elixir refuse: the #{length} byte prefix of #{path} was ACCEPTED")
      end
    end)

    IO.puts("interop elixir: refused all #{byte_size(input)} truncated prefixes of #{path}")
  end

  defp die(message) do
    IO.puts(:stderr, message)
    System.halt(1)
  end

  def main(["write", path]), do: write(path)
  def main(["read", path]), do: read(path)
  def main(["refuse", path]), do: refuse(path)

  def main(_argv) do
    IO.puts(:stderr, "usage: mix run interop/interop.exs write|read|refuse <file>")
    System.halt(2)
  end
end

Serialize.Interop.main(System.argv())
