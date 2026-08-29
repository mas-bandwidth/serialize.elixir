defmodule Serialize.GoldenWireTest do
  use ExUnit.Case, async: true

  import Bitwise

  alias Serialize.{MeasureStream, ReadStream, WriteStream}
  alias Serialize.Test.GoldenWire

  @golden GoldenWire.golden_wire_bytes()
  @golden_bits GoldenWire.golden_bits()

  test "write side: serializing the golden values produces exactly the golden bytes" do
    {:ok, stream, _values} = GoldenWire.serialize(WriteStream.new(), GoldenWire.values())
    stream = WriteStream.flush(stream)
    assert Serialize.bytes_processed(stream) == byte_size(@golden)
    assert Serialize.bits_processed(stream) == @golden_bits
    assert WriteStream.data(stream) == @golden
  end

  test "read side: the golden bytes decode to the expected values, on every platform, forever" do
    {:ok, stream, decoded} =
      GoldenWire.serialize(ReadStream.new(@golden), GoldenWire.zero_values())

    assert Serialize.bits_processed(stream) == @golden_bits
    expected = GoldenWire.values()

    for key <- Map.keys(expected) do
      assert GoldenWire.matches?(Map.take(decoded, [key]), Map.take(expected, [key])),
             "#{key}: decoded #{inspect(decoded[key])}, expected #{inspect(expected[key])}"
    end
  end

  test "trailing bits: the writer zeroes them and the reader is indifferent to them" do
    # writer obligation, small stream: a message ending 3 bits into its
    # final byte. the writer owns its output, so the zeros can only come
    # from the writer.
    stream = WriteStream.new()
    {:ok, stream, _} = Serialize.serialize_bits(stream, 0xDEADBEEF, 32)
    {:ok, stream, _} = Serialize.serialize_bits(stream, 5, 3)
    stream = WriteStream.flush(stream)

    data = WriteStream.data(stream)
    bits_in_final_byte = rem(Serialize.bits_processed(stream), 8)
    assert bits_in_final_byte == 3
    trailing_mask = 0xFF <<< bits_in_final_byte &&& 0xFF
    assert (:binary.last(data) &&& trailing_mask) == 0

    # reader indifference, small stream: set every trailing bit and read
    # back. the doctored stream must be accepted and decode the same values.
    doctored = doctor_last_byte(data, trailing_mask)
    reader = ReadStream.new(doctored)
    {:ok, reader, head} = Serialize.serialize_bits(reader, 0, 32)
    assert head == 0xDEADBEEF
    {:ok, _reader, tail} = Serialize.serialize_bits(reader, 0, 3)
    assert tail == 5
  end

  test "trailing bits: a doctored golden stream decodes identically" do
    bits_in_final_byte = rem(@golden_bits, 8)
    assert bits_in_final_byte != 0
    trailing_mask = 0xFF <<< bits_in_final_byte &&& 0xFF
    assert (:binary.last(@golden) &&& trailing_mask) == 0

    doctored = doctor_last_byte(@golden, trailing_mask)

    {:ok, stream, decoded} =
      GoldenWire.serialize(ReadStream.new(doctored), GoldenWire.zero_values())

    assert GoldenWire.matches?(decoded, GoldenWire.values())
    assert Serialize.bits_processed(stream) == @golden_bits
  end

  test "past-end poison: bytes past the stream end are never interpreted" do
    # the reader prices its windows inside the binary, so the proof here is
    # the contract's observable half: poison immediately past the data view
    # (in the same underlying binary) changes nothing on the accept path.
    clean_buffer = @golden <> :binary.copy(<<0>>, 144)
    poison_buffer = @golden <> :binary.copy(<<0xFF>>, 144)

    clean = ReadStream.new(binary_part(clean_buffer, 0, byte_size(@golden)))
    poison = ReadStream.new(binary_part(poison_buffer, 0, byte_size(@golden)))

    {:ok, clean, clean_decoded} = GoldenWire.serialize(clean, GoldenWire.zero_values())
    {:ok, poison, poison_decoded} = GoldenWire.serialize(poison, GoldenWire.zero_values())

    assert GoldenWire.matches?(clean_decoded, GoldenWire.values())
    assert GoldenWire.matches?(poison_decoded, GoldenWire.values())
    assert Serialize.bits_processed(poison) == Serialize.bits_processed(clean)
  end

  test "past-end poison: a truncated stream refuses identically regardless of the tail" do
    truncated_bytes = byte_size(@golden) - 1
    truncated = binary_part(@golden, 0, truncated_bytes)

    clean_buffer = truncated <> :binary.copy(<<0>>, 145)
    poison_buffer = truncated <> :binary.copy(<<0xFF>>, 145)

    clean = ReadStream.new(binary_part(clean_buffer, 0, truncated_bytes))
    poison = ReadStream.new(binary_part(poison_buffer, 0, truncated_bytes))

    {:error, clean} = GoldenWire.serialize(clean, GoldenWire.zero_values())
    {:error, poison} = GoldenWire.serialize(poison, GoldenWire.zero_values())

    # refused at the same point
    assert Serialize.bits_processed(poison) == Serialize.bits_processed(clean)
  end

  test "measure bounds the write at every one of the 8 starting offsets" do
    for offset <- 0..7 do
      writer = WriteStream.new()

      writer =
        if offset > 0 do
          {:ok, writer, _} = Serialize.serialize_bits(writer, 0, offset)
          writer
        else
          writer
        end

      {:ok, writer, _} = GoldenWire.serialize(writer, GoldenWire.values())

      measure = MeasureStream.new()

      measure =
        if offset > 0 do
          {:ok, measure, _} = Serialize.serialize_bits(measure, 0, offset)
          measure
        else
          measure
        end

      {:ok, measure, _} = GoldenWire.serialize(measure, GoldenWire.values())

      assert Serialize.bits_processed(measure) >= Serialize.bits_processed(writer),
             "offset #{offset}: measured #{Serialize.bits_processed(measure)} bits, " <>
               "wrote #{Serialize.bits_processed(writer)}"
    end
  end

  test "the sabotage sweep: flipping any consumed bit defeats the battery, and no flip ever raises" do
    # every one of the 891 consumed bits of the golden stream is load
    # bearing: flipping any single one must make the read refuse or produce
    # different values. the 5 trailing bits are the exact complement:
    # flipping any of them must change nothing at all. hostile data never
    # raises anywhere in the sweep.
    values = GoldenWire.values()

    for bit <- 0..(byte_size(@golden) * 8 - 1) do
      doctored = flip_bit(@golden, bit)

      result = GoldenWire.serialize(ReadStream.new(doctored), GoldenWire.zero_values())

      matches =
        case result do
          {:ok, _stream, decoded} -> GoldenWire.matches?(decoded, values)
          {:error, _stream} -> false
        end

      if bit < @golden_bits do
        refute matches, "consumed bit #{bit} flipped: the doctored stream still decoded golden"
      else
        assert matches, "trailing bit #{bit} flipped: the doctored stream was not accepted"
        {:ok, stream, _decoded} = result
        assert Serialize.bits_processed(stream) == @golden_bits
      end
    end
  end

  defp doctor_last_byte(data, mask) do
    head = binary_part(data, 0, byte_size(data) - 1)
    <<head::binary, :binary.last(data) ||| mask>>
  end

  defp flip_bit(data, bit) do
    byte_index = bit >>> 3
    <<head::binary-size(^byte_index), byte, tail::binary>> = data
    <<head::binary, bxor(byte, 1 <<< (bit &&& 7)), tail::binary>>
  end
end
