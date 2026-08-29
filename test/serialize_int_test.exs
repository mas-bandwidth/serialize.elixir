defmodule Serialize.IntTest do
  use ExUnit.Case, async: true

  import Bitwise

  alias Serialize.{MeasureStream, ReadStream, WriteStream}

  @int32_min -2_147_483_648
  @int32_max 2_147_483_647
  @int64_min -0x8000000000000000
  @int64_max 0x7FFFFFFFFFFFFFFF

  defp round_trip(op, value, min, max) do
    {:ok, writer, ^value} = apply(Serialize, op, [WriteStream.new(), value, min, max])
    writer = WriteStream.flush(writer)

    {:ok, reader, decoded} =
      apply(Serialize, op, [ReadStream.new(WriteStream.data(writer)), nil, min, max])

    {decoded, Serialize.bits_processed(writer), Serialize.bits_processed(reader)}
  end

  describe "serialize_int" do
    test "round-trips across the range" do
      for {value, min, max} <- [
            {-37, -100, 100},
            {-100, -100, 100},
            {100, -100, 100},
            {0, @int32_min, @int32_max},
            {@int32_min, @int32_min, @int32_max},
            {@int32_max, @int32_min, @int32_max},
            {5, 0, 7},
            {8, 0, 8}
          ] do
        {decoded, written, read} = round_trip(:serialize_int, value, min, max)
        assert decoded == value
        assert written == Serialize.Bits.bits_required(min, max)
        assert read == written
      end
    end

    test "a degenerate range costs zero bits and decodes from the range alone" do
      {:ok, writer, 42} = Serialize.serialize_int(WriteStream.new(), 42, 42, 42)
      assert Serialize.bits_processed(writer) == 0
      {:ok, reader, 42} = Serialize.serialize_int(ReadStream.new(<<>>), nil, 42, 42)
      assert Serialize.bits_processed(reader) == 0
    end

    test "the reader rejects an offset above the range" do
      # range [0,5] is 3 bits; the codes 6 and 7 fit the field but not the range
      reader = ReadStream.new(<<7>>)
      assert {:error, _stream} = Serialize.serialize_int(reader, nil, 0, 5)
    end

    test "the reader refuses a truncated stream" do
      assert {:error, _stream} = Serialize.serialize_int(ReadStream.new(<<0xFF>>), nil, 0, 1000)
    end

    test "caller misuse raises on write" do
      assert_raise ArgumentError, fn ->
        Serialize.serialize_int(WriteStream.new(), 101, -100, 100)
      end

      assert_raise FunctionClauseError, fn ->
        Serialize.serialize_int(WriteStream.new(), 0, 100, -100)
      end
    end
  end

  describe "serialize_int64" do
    test "round-trips across the range, splitting wide values low group first" do
      for {value, min, max} <- [
            {-5_000_000_000, -5_000_000_000, 5_000_000_000},
            {5_000_000_000, -5_000_000_000, 5_000_000_000},
            {0, @int64_min, @int64_max},
            {@int64_min, @int64_min, @int64_max},
            {@int64_max, @int64_min, @int64_max},
            {1 <<< 40, 0, 1 <<< 41}
          ] do
        {decoded, written, _read} = round_trip(:serialize_int64, value, min, max)
        assert decoded == value
        assert written == Serialize.Bits.bits_required(min, max)
      end
    end

    test "matches serialize_int byte for byte where the range fits 32 bits" do
      {:ok, w32, _} = Serialize.serialize_int(WriteStream.new(), -37, -100, 100)
      {:ok, w64, _} = Serialize.serialize_int64(WriteStream.new(), -37, -100, 100)
      assert WriteStream.data(WriteStream.flush(w32)) == WriteStream.data(WriteStream.flush(w64))
    end

    test "the reader rejects an offset above the range" do
      # range [0, 2^33] needs 34 bits; an offset of 2^33 + 1 fits the field
      offset = (1 <<< 33) + 1
      writer = WriteStream.new()
      {:ok, writer, _} = Serialize.serialize_bits(writer, offset &&& 0xFFFFFFFF, 32)
      {:ok, writer, _} = Serialize.serialize_bits(writer, offset >>> 32, 2)
      data = WriteStream.data(WriteStream.flush(writer))
      assert {:error, _} = Serialize.serialize_int64(ReadStream.new(data), nil, 0, 1 <<< 33)
    end

    test "a refused truncated read consumes nothing (checked against the total width)" do
      reader = ReadStream.new(<<0xFF, 0xFF, 0xFF, 0xFF>>)
      {:error, reader} = Serialize.serialize_int64(reader, nil, 0, 1 <<< 40)
      assert Serialize.bits_processed(reader) == 0
    end
  end

  describe "serialize_int128" do
    test "round-trips the wide shapes" do
      min = -(1 <<< 127)
      max = (1 <<< 127) - 1

      for value <- [min, max, 0, -1, 1 <<< 100, -(1 <<< 100)] do
        {decoded, written, _read} = round_trip(:serialize_int128, value, min, max)
        assert decoded == value
        assert written == 128
      end
    end

    test "matches serialize_int64 byte for byte where the range fits 64 bits" do
      min = -5_000_000_000
      max = 5_000_000_000

      for value <- [min, min + 1, -1, 0, 1, 4_123_456_789, max - 1, max] do
        {:ok, w64, _} = Serialize.serialize_int64(WriteStream.new(), value, min, max)
        {:ok, w128, _} = Serialize.serialize_int128(WriteStream.new(), value, min, max)

        assert WriteStream.data(WriteStream.flush(w64)) ==
                 WriteStream.data(WriteStream.flush(w128))
      end
    end

    test "the golden three-group vector: +/-2^70 bounds, 72 bits" do
      # serialize.h golden_int128_bytes, copied mechanically. The reference
      # pins 12 bytes against its zeroed buffer; the stream itself is 72
      # bits = 9 bytes, and the final 3 golden bytes are that buffer's
      # zeros beyond the stream.
      golden = <<0x11, 0x32, 0x54, 0x76, 0x98, 0xBA, 0xDC, 0xFE, 0x3F, 0x00, 0x00, 0x00>>
      min = -(1 <<< 70)
      max = 1 <<< 70
      value = -0x0123456789ABCDEF

      {:ok, writer, _} = Serialize.serialize_int128(WriteStream.new(), value, min, max)
      writer = WriteStream.flush(writer)
      assert Serialize.bits_processed(writer) == 72
      assert WriteStream.data(writer) == binary_part(golden, 0, 9)

      {:ok, _reader, decoded} = Serialize.serialize_int128(ReadStream.new(golden), nil, min, max)
      assert decoded == value
    end

    test "a truncated buffer is refused rather than read past the end" do
      reader = ReadStream.new(<<0, 0, 0, 0>>)
      min = -(1 <<< 127)
      max = (1 <<< 127) - 1
      assert {:error, _} = Serialize.serialize_int128(reader, nil, min, max)
    end

    test "the reader rejects an offset above the range" do
      # range [0, 2^70]: 71 bits; offset 2^70 + 1 fits the field
      offset = (1 <<< 70) + 1
      writer = WriteStream.new()
      {:ok, writer, _} = Serialize.serialize_bits(writer, offset &&& 0xFFFFFFFF, 32)
      {:ok, writer, _} = Serialize.serialize_bits(writer, offset >>> 32 &&& 0xFFFFFFFF, 32)
      {:ok, writer, _} = Serialize.serialize_bits(writer, offset >>> 64, 7)
      data = WriteStream.data(WriteStream.flush(writer))
      assert {:error, _} = Serialize.serialize_int128(ReadStream.new(data), nil, 0, 1 <<< 70)
    end

    test "the bounds must satisfy min < max strictly, as the reference asserts" do
      assert_raise FunctionClauseError, fn ->
        Serialize.serialize_int128(WriteStream.new(), 5, 5, 5)
      end
    end
  end

  test "measure charges the exact range width for all three widths" do
    measure = MeasureStream.new()
    {:ok, measure, _} = Serialize.serialize_int(measure, 0, -100, 100)
    {:ok, measure, _} = Serialize.serialize_int64(measure, 0, @int64_min, @int64_max)
    {:ok, measure, _} = Serialize.serialize_int128(measure, 0, -(1 <<< 70), 1 <<< 70)
    assert Serialize.bits_processed(measure) == 8 + 64 + 72
  end
end
