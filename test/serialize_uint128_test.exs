defmodule Serialize.Uint128Test do
  use ExUnit.Case, async: true

  import Bitwise

  alias Serialize.{ReadStream, WriteStream}

  # serialize.h golden_uint128_bytes: the 16 bytes of the value in
  # little-endian order, low half first. Pinned forever.
  @golden_uint128_bytes <<0x10, 0x32, 0x54, 0x76, 0x98, 0xBA, 0xDC, 0xFE, 0xEF, 0xCD, 0xAB, 0x89,
                          0x67, 0x45, 0x23, 0x01>>
  @golden_value 0x0123456789ABCDEF <<< 64 ||| 0xFEDCBA9876543210

  test "the golden pin: a uint128 is its 16 bytes in little-endian order" do
    {:ok, writer, _} = Serialize.serialize_uint128(WriteStream.new(), @golden_value)
    writer = WriteStream.flush(writer)
    assert Serialize.bytes_processed(writer) == 16
    assert WriteStream.data(writer) == @golden_uint128_bytes

    {:ok, _reader, decoded} =
      Serialize.serialize_uint128(ReadStream.new(@golden_uint128_bytes), nil)

    assert decoded == @golden_value
  end

  test "byte-identical to two serialize_uint64 calls, low half first" do
    {:ok, halves, _} =
      Serialize.serialize_uint64(WriteStream.new(), @golden_value &&& 0xFFFFFFFFFFFFFFFF)

    {:ok, halves, _} = Serialize.serialize_uint64(halves, @golden_value >>> 64)
    {:ok, whole, _} = Serialize.serialize_uint128(WriteStream.new(), @golden_value)

    assert WriteStream.data(WriteStream.flush(halves)) ==
             WriteStream.data(WriteStream.flush(whole))
  end

  test "round-trips the extremes" do
    for value <- [0, 1, (1 <<< 128) - 1, 1 <<< 127, 1 <<< 64] do
      {:ok, writer, ^value} = Serialize.serialize_uint128(WriteStream.new(), value)
      writer = WriteStream.flush(writer)

      {:ok, _reader, decoded} =
        Serialize.serialize_uint128(ReadStream.new(WriteStream.data(writer)), nil)

      assert decoded == value
    end
  end

  test "a truncated read refuses" do
    assert {:error, _} = Serialize.serialize_uint128(ReadStream.new(<<0::96>>), nil)
  end

  test "caller misuse raises on write" do
    assert_raise ArgumentError, fn -> Serialize.serialize_uint128(WriteStream.new(), -1) end

    assert_raise ArgumentError, fn ->
      Serialize.serialize_uint128(WriteStream.new(), 1 <<< 128)
    end
  end
end
