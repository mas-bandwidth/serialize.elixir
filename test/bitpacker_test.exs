defmodule Serialize.BitpackerTest do
  use ExUnit.Case, async: true

  import Bitwise

  alias Serialize.{BitReader, BitWriter}

  test "values pack least-significant-bit first into little-endian words" do
    # 3 bits of 0b101, then 5 bits of 0b10010: first byte = 0b10010_101
    writer =
      BitWriter.new()
      |> BitWriter.write_bits(0b101, 3)
      |> BitWriter.write_bits(0b10010, 5)
      |> BitWriter.flush()

    assert BitWriter.data(writer) == <<0b10010101>>
  end

  test "a value crossing the 64-bit word boundary splits low bits first" do
    # 60 zero bits, then 8 bits of 0xAB: the low nibble completes word 0,
    # the high nibble begins word 1
    writer =
      BitWriter.new()
      |> BitWriter.write_bits(0, 30)
      |> BitWriter.write_bits(0, 30)
      |> BitWriter.write_bits(0xAB, 8)
      |> BitWriter.flush()

    data = BitWriter.data(writer)
    assert byte_size(data) == 9
    assert :binary.part(data, 7, 2) == <<0xB0, 0x0A>>

    reader = BitReader.new(data)
    {_zero, reader} = BitReader.read_bits(reader, 30)
    {_zero, reader} = BitReader.read_bits(reader, 30)
    {value, _reader} = BitReader.read_bits(reader, 8)
    assert value == 0xAB
  end

  test "write then read round-trips a mixed sequence exactly" do
    fields = [{7, 3}, {0, 1}, {123_456, 17}, {1, 1}, {0xFFFFFFFF, 32}, {5, 11}, {0x3FF, 10}]

    writer =
      Enum.reduce(fields, BitWriter.new(), fn {value, bits}, writer ->
        BitWriter.write_bits(writer, value, bits)
      end)

    total_bits = Enum.sum(for {_v, bits} <- fields, do: bits)
    assert BitWriter.bits_written(writer) == total_bits

    writer = BitWriter.flush(writer)
    reader = BitReader.new(BitWriter.data(writer))

    {read_back, _reader} =
      Enum.map_reduce(fields, reader, fn {_value, bits}, reader ->
        BitReader.read_bits(reader, bits)
      end)

    assert read_back == for({value, _bits} <- fields, do: value)
  end

  test "the writer masks values to the field width" do
    writer =
      BitWriter.new()
      |> BitWriter.write_bits(0xFF, 4)
      |> BitWriter.write_bits(0, 4)
      |> BitWriter.flush()

    assert BitWriter.data(writer) == <<0x0F>>
  end

  test "align pads with zeros to the byte boundary and is a no-op when aligned" do
    writer = BitWriter.new() |> BitWriter.write_bits(1, 1) |> BitWriter.write_align()
    assert BitWriter.bits_written(writer) == 8
    assert BitWriter.align_bits(writer) == 0

    # aligned: nothing written
    writer = BitWriter.write_align(writer)
    assert BitWriter.bits_written(writer) == 8
    assert BitWriter.data(BitWriter.flush(writer)) == <<0x01>>
  end

  test "write_bytes lands the payload at the byte cursor and later bits pack after it" do
    writer =
      BitWriter.new()
      |> BitWriter.write_bits(0x5, 3)
      |> BitWriter.write_align()
      |> BitWriter.write_bytes(<<0xDE, 0xAD, 0xBE, 0xEF, 0xCA, 0xFE, 0x01, 0x23, 0x45>>)
      |> BitWriter.write_bits(0xF, 4)
      |> BitWriter.flush()

    assert BitWriter.data(writer) ==
             <<0x05, 0xDE, 0xAD, 0xBE, 0xEF, 0xCA, 0xFE, 0x01, 0x23, 0x45, 0x0F>>
  end

  test "the reader verifies align padding is zero" do
    # 0xFF: one bit consumed, the 7 pad bits are all ones
    reader = BitReader.new(<<0xFF>>)
    {1, reader} = BitReader.read_bits(reader, 1)
    assert {:error, _reader} = BitReader.read_align(reader)

    # 0x01: one bit consumed, the 7 pad bits are zero
    reader = BitReader.new(<<0x01>>)
    {1, reader} = BitReader.read_bits(reader, 1)
    assert {:ok, reader} = BitReader.read_align(reader)
    assert BitReader.bits_read(reader) == 8
  end

  test "would_read_past_end? prices the exact bit budget" do
    reader = BitReader.new(<<0xAB, 0xCD>>)
    refute BitReader.would_read_past_end?(reader, 16)
    assert BitReader.would_read_past_end?(reader, 17)
    {_value, reader} = BitReader.read_bits(reader, 9)
    refute BitReader.would_read_past_end?(reader, 7)
    assert BitReader.would_read_past_end?(reader, 8)
    assert BitReader.bits_remaining(reader) == 7
  end

  test "reads near the end of the data stay inside the binary" do
    # a 2-byte stream: the window for the final bits cannot assume 8 bytes
    reader = BitReader.new(<<0x34, 0x12>>)
    {value, reader} = BitReader.read_bits(reader, 16)
    assert value == 0x1234
    assert BitReader.bits_remaining(reader) == 0
  end

  test "trailing bits of the final byte flush as zeros" do
    writer = BitWriter.new() |> BitWriter.write_bits(0b101, 3) |> BitWriter.flush()
    <<byte>> = BitWriter.data(writer)
    assert byte == 0b101
    assert (byte &&& 0b11111000) == 0
  end

  test "bytes_written rounds the bit count up" do
    writer = BitWriter.new() |> BitWriter.write_bits(1, 1)
    assert BitWriter.bytes_written(writer) == 1
    writer = BitWriter.write_bits(writer, 0x7F, 8)
    assert BitWriter.bytes_written(writer) == 2
  end
end
