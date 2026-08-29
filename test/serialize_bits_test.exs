defmodule Serialize.BitsOpTest do
  use ExUnit.Case, async: true

  import Bitwise

  alias Serialize.{MeasureStream, ReadStream, WriteStream}

  test "round-trips every width from 1 to 64" do
    for bits <- 1..64 do
      value = Serialize.Bits.mask(bits) &&& 0xA5A5A5A5A5A5A5A5

      {:ok, writer, ^value} = Serialize.serialize_bits(WriteStream.new(), value, bits)
      assert Serialize.bits_processed(writer) == bits

      writer = WriteStream.flush(writer)
      reader = ReadStream.new(WriteStream.data(writer))
      {:ok, reader, decoded} = Serialize.serialize_bits(reader, nil, bits)
      assert decoded == value
      assert Serialize.bits_processed(reader) == bits
    end
  end

  test "wide values split low 32 bits first, then the high remainder" do
    {:ok, writer, _} = Serialize.serialize_bits(WriteStream.new(), 0x0000AB_12345678, 48)
    data = WriteStream.data(WriteStream.flush(writer))
    assert data == <<0x78, 0x56, 0x34, 0x12, 0xAB, 0x00>>
  end

  test "the uint helpers are aliases at their widths" do
    writer = WriteStream.new()
    {:ok, writer, _} = Serialize.serialize_uint8(writer, 0x7F)
    {:ok, writer, _} = Serialize.serialize_uint16(writer, 0x1234)
    {:ok, writer, _} = Serialize.serialize_uint32(writer, 0x12345678)
    {:ok, writer, _} = Serialize.serialize_uint64(writer, 0x123456789ABCDEF0)
    assert Serialize.bits_processed(writer) == 8 + 16 + 32 + 64

    data = WriteStream.data(WriteStream.flush(writer))

    assert data ==
             <<0x7F, 0x34, 0x12, 0x78, 0x56, 0x34, 0x12, 0xF0, 0xDE, 0xBC, 0x9A, 0x78, 0x56, 0x34,
               0x12>>

    reader = ReadStream.new(data)
    {:ok, reader, 0x7F} = Serialize.serialize_uint8(reader, nil)
    {:ok, reader, 0x1234} = Serialize.serialize_uint16(reader, nil)
    {:ok, reader, 0x12345678} = Serialize.serialize_uint32(reader, nil)
    {:ok, _reader, 0x123456789ABCDEF0} = Serialize.serialize_uint64(reader, nil)
  end

  test "a truncated read refuses; the split's first group may already be consumed" do
    # 40-bit read against 32 bits of data: the low group succeeds, the high
    # group refuses — the reference macro's two-call shape
    reader = ReadStream.new(<<1, 2, 3, 4>>)
    {:error, reader} = Serialize.serialize_bits(reader, nil, 40)
    assert Serialize.bits_processed(reader) == 32
  end

  test "serialize_bool is one bit and reads back both values" do
    writer = WriteStream.new()
    {:ok, writer, true} = Serialize.serialize_bool(writer, true)
    {:ok, writer, false} = Serialize.serialize_bool(writer, false)
    assert Serialize.bits_processed(writer) == 2

    reader = ReadStream.new(WriteStream.data(WriteStream.flush(writer)))
    {:ok, reader, true} = Serialize.serialize_bool(reader, nil)
    {:ok, _reader, false} = Serialize.serialize_bool(reader, nil)

    # an empty stream refuses the one-bit read
    assert {:error, _} = Serialize.serialize_bool(ReadStream.new(<<>>), nil)
  end

  test "caller misuse raises on write" do
    assert_raise ArgumentError, fn -> Serialize.serialize_bits(WriteStream.new(), 16, 4) end
    assert_raise ArgumentError, fn -> Serialize.serialize_bits(WriteStream.new(), -1, 4) end

    # the truncation check on the wide path is per 32-bit group: a value
    # whose high group overflows its width raises
    assert_raise ArgumentError, fn ->
      Serialize.serialize_bits(WriteStream.new(), 1 <<< 45, 40)
    end

    assert_raise FunctionClauseError, fn -> Serialize.serialize_bits(WriteStream.new(), 0, 0) end
    assert_raise FunctionClauseError, fn -> Serialize.serialize_bits(WriteStream.new(), 0, 65) end
    assert_raise ArgumentError, fn -> Serialize.serialize_bool(WriteStream.new(), 1) end
  end

  test "measure charges the exact width" do
    measure = MeasureStream.new()
    {:ok, measure, _} = Serialize.serialize_bits(measure, 0, 11)
    {:ok, measure, _} = Serialize.serialize_bits(measure, 0, 64)
    {:ok, measure, _} = Serialize.serialize_uint128(measure, 0)
    assert Serialize.bits_processed(measure) == 11 + 64 + 128
  end
end
