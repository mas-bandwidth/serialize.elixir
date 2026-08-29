defmodule Serialize.FixedTest do
  use ExUnit.Case, async: true

  import Bitwise

  alias Serialize.{MeasureStream, ReadStream, WriteStream}

  @int64_min -0x8000000000000000
  @int64_max 0x7FFFFFFFFFFFFFFF

  defp round_trip(value, ib, fb, min, max) do
    {:ok, writer, ^value} = Serialize.serialize_fixed(WriteStream.new(), value, ib, fb, min, max)
    writer = WriteStream.flush(writer)
    reader = ReadStream.new(WriteStream.data(writer))
    {:ok, reader, decoded} = Serialize.serialize_fixed(reader, nil, ib, fb, min, max)
    {decoded, Serialize.bits_processed(writer), Serialize.bits_processed(reader)}
  end

  test "the golden shapes round-trip exactly at their pinned widths" do
    # {value, integer_bits, fraction_bits, min, max, wire bits}
    cases = [
      # -3.25 in Q8.8 over [-100,100]: 16 bits
      {-(3 * 256 + 64), 8, 8, -100, 100, 16},
      # 1234.5 in Q16.16 over [-2000,2000]: 28 bits
      {1234 * 65536 + 32768, 16, 16, -2000, 2000, 28},
      # Q48.16 over [-100000,100000]: 34 bits, the two-group shape
      {-(54_321 * 65536 + 12_345), 48, 16, -100_000, 100_000, 34},
      # unsigned Q16.16 over [0,30000]: 31 bits
      {29_999 * 65536 + 65_535, 16, 16, 0, 30_000, 31},
      # Q112.16 over +/-2^57 units: 75 bits, the three-group shape
      {-(98_765_432_109 * 65536 + 4321), 112, 16, -144_115_188_075_855_872,
       144_115_188_075_855_872, 75},
      # Q64.64 over the full unit range: 128 bits, the four-group shape
      {0x0123456789ABCDEF <<< 64 ||| 0x0FEDCBA987654321, 64, 64, @int64_min, @int64_max, 128}
    ]

    for {value, ib, fb, min, max, bits} <- cases do
      {decoded, written, read} = round_trip(value, ib, fb, min, max)
      assert decoded == value
      assert written == bits
      assert read == bits
    end
  end

  test "bounds round-trip on every shape" do
    for {ib, fb, min, max} <- [
          {8, 8, -100, 100},
          {16, 0, -30_000, 30_000},
          {32, 0, 0, 4_000_000},
          {48, 16, -100_000, 100_000},
          {64, 64, @int64_min, @int64_max}
        ] do
      raw_min = min <<< fb
      raw_max = max <<< fb

      for value <- [raw_min, raw_max, raw_min + 1, raw_max - 1] do
        {decoded, _written, _read} = round_trip(value, ib, fb, min, max)
        assert decoded == value
      end
    end
  end

  test "fixed with fraction_bits 0 is byte-identical to the ranged integer" do
    {:ok, fixed, _} = Serialize.serialize_fixed(WriteStream.new(), -37, 32, 0, -100, 100)
    {:ok, int, _} = Serialize.serialize_int(WriteStream.new(), -37, -100, 100)
    assert WriteStream.data(WriteStream.flush(fixed)) == WriteStream.data(WriteStream.flush(int))
  end

  test "narrow fixed is byte-identical to serialize_int64 of the raw value over the raw bounds" do
    value = -(54_321 * 65536 + 12_345)

    {:ok, fixed, _} =
      Serialize.serialize_fixed(WriteStream.new(), value, 48, 16, -100_000, 100_000)

    {:ok, int64, _} =
      Serialize.serialize_int64(WriteStream.new(), value, -100_000 <<< 16, 100_000 <<< 16)

    assert WriteStream.data(WriteStream.flush(fixed)) ==
             WriteStream.data(WriteStream.flush(int64))
  end

  test "a degenerate range costs zero bits on every storage width" do
    for {ib, fb} <- [{8, 8}, {16, 16}, {48, 16}, {112, 16}, {64, 64}] do
      {:ok, writer, raw} = Serialize.serialize_fixed(WriteStream.new(), 7 <<< fb, ib, fb, 7, 7)
      assert raw == 7 <<< fb
      assert Serialize.bits_processed(writer) == 0

      {:ok, reader, decoded} = Serialize.serialize_fixed(ReadStream.new(<<>>), nil, ib, fb, 7, 7)
      assert decoded == 7 <<< fb
      assert Serialize.bits_processed(reader) == 0
    end
  end

  test "the reader rejects an offset above the raw range — reject, never clamp" do
    # Q8.8 over [-100,100]: raw range 51200 in a 16-bit field; the code
    # 51201 fits the field but not the range
    {:ok, writer, _} = Serialize.serialize_bits(WriteStream.new(), 51_201, 16)
    data = WriteStream.data(WriteStream.flush(writer))
    assert {:error, _} = Serialize.serialize_fixed(ReadStream.new(data), nil, 8, 8, -100, 100)

    # the wide path rejects too: 75-bit field, offset above the raw range
    raw_range = (144_115_188_075_855_872 * 2) <<< 16
    offset = raw_range + 1
    writer = WriteStream.new()
    {:ok, writer, _} = Serialize.serialize_bits(writer, offset &&& 0xFFFFFFFF, 32)
    {:ok, writer, _} = Serialize.serialize_bits(writer, offset >>> 32 &&& 0xFFFFFFFF, 32)
    {:ok, writer, _} = Serialize.serialize_bits(writer, offset >>> 64, 11)
    data = WriteStream.data(WriteStream.flush(writer))

    assert {:error, _} =
             Serialize.serialize_fixed(
               ReadStream.new(data),
               nil,
               112,
               16,
               -144_115_188_075_855_872,
               144_115_188_075_855_872
             )
  end

  test "truncated reads refuse" do
    assert {:error, _} = Serialize.serialize_fixed(ReadStream.new(<<0xFF>>), nil, 8, 8, -100, 100)

    assert {:error, _} =
             Serialize.serialize_fixed(
               ReadStream.new(<<0::64>>),
               nil,
               64,
               64,
               @int64_min,
               @int64_max
             )
  end

  test "caller misuse raises: format shape, capacity, value range" do
    # integer_bits + fraction_bits must equal a storage width
    assert_raise ArgumentError, fn ->
      Serialize.serialize_fixed(WriteStream.new(), 0, 8, 9, -100, 100)
    end

    # signed capacity: Q8.8 whole units live in [-128,127]
    assert_raise ArgumentError, fn ->
      Serialize.serialize_fixed(WriteStream.new(), 0, 8, 8, -200, 100)
    end

    # unsigned capacity: Q16.16 with min >= 0 caps at 65535 whole units
    assert_raise ArgumentError, fn ->
      Serialize.serialize_fixed(WriteStream.new(), 0, 16, 16, 0, 70_000)
    end

    # value outside the declared range
    assert_raise ArgumentError, fn ->
      Serialize.serialize_fixed(WriteStream.new(), 101 <<< 8, 8, 8, -100, 100)
    end

    # degenerate range: the value must be the range's raw value
    assert_raise ArgumentError, fn ->
      Serialize.serialize_fixed(WriteStream.new(), 8 <<< 8, 8, 8, 7, 7)
    end
  end

  test "measure charges the exact raw-range width" do
    measure = MeasureStream.new()
    {:ok, measure, _} = Serialize.serialize_fixed(measure, 0, 8, 8, -100, 100)
    assert Serialize.bits_processed(measure) == 16

    {:ok, measure, _} =
      Serialize.serialize_fixed(
        measure,
        0,
        112,
        16,
        -144_115_188_075_855_872,
        144_115_188_075_855_872
      )

    assert Serialize.bits_processed(measure) == 16 + 75
  end
end
