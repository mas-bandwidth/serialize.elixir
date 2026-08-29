defmodule Serialize.FloatTest do
  use ExUnit.Case, async: true

  alias Serialize.{Float32, MeasureStream, ReadStream, WriteStream}

  # serialize.h golden_float_bytes / golden_float_patterns /
  # golden_double_patterns: the patterns a sanitizing implementation
  # breaks, compared by bits, never by value.
  @golden_float_bytes <<0x01, 0x00, 0xC0, 0x7F, 0x01, 0x00, 0x80, 0x7F, 0x00, 0x00, 0x80, 0xFF,
                        0x00, 0x00, 0x00, 0x80, 0x01, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00,
                        0x00, 0x00, 0xF4, 0x7F, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x80>>

  # quiet NaN payload 1, signaling NaN, -Inf, -0.0, smallest denormal
  @golden_float_patterns [0x7FC00001, 0x7F800001, 0xFF800000, 0x80000000, 0x00000001]
  # f64 signaling NaN payload 1, f64 -0.0
  @golden_double_patterns [0x7FF4000000000001, 0x8000000000000000]

  defp serialize_golden_floats(stream, floats, doubles) do
    with {:ok, stream, f} <-
           Enum.reduce_while(floats, {:ok, stream, []}, fn value, {:ok, stream, acc} ->
             case Serialize.serialize_float(stream, value) do
               {:ok, stream, decoded} -> {:cont, {:ok, stream, [decoded | acc]}}
               error -> {:halt, error}
             end
           end),
         {:ok, stream, d} <-
           Enum.reduce_while(doubles, {:ok, stream, []}, fn value, {:ok, stream, acc} ->
             case Serialize.serialize_double(stream, value) do
               {:ok, stream, decoded} -> {:cont, {:ok, stream, [decoded | acc]}}
               error -> {:halt, error}
             end
           end) do
      {:ok, stream, Enum.reverse(f), Enum.reverse(d)}
    end
  end

  test "bit transparency: the golden non-finite patterns write exactly the pinned bytes" do
    floats = Enum.map(@golden_float_patterns, &Float32.value32/1)
    doubles = Enum.map(@golden_double_patterns, &Float32.value64/1)

    {:ok, writer, _f, _d} = serialize_golden_floats(WriteStream.new(), floats, doubles)
    writer = WriteStream.flush(writer)
    assert Serialize.bytes_processed(writer) == byte_size(@golden_float_bytes)
    assert WriteStream.data(writer) == @golden_float_bytes
  end

  test "bit transparency: the pinned bytes decode to the exact transmitted patterns" do
    reader = ReadStream.new(@golden_float_bytes)
    nils = List.duplicate(nil, 5)

    {:ok, _reader, floats, doubles} = serialize_golden_floats(reader, nils, [nil, nil])

    read_float_patterns =
      Enum.map(floats, fn
        {:nonfinite, bits} -> bits
        value -> Float32.bits32(value)
      end)

    read_double_patterns =
      Enum.map(doubles, fn
        {:nonfinite, bits} -> bits
        value -> Float32.bits64(value)
      end)

    assert read_float_patterns == @golden_float_patterns
    assert read_double_patterns == @golden_double_patterns
  end

  test "the non-finite surface is pinned: NaN and infinity patterns travel as {:nonfinite, bits}" do
    {:ok, reader, value} =
      Serialize.serialize_float(ReadStream.new(<<0x00, 0x00, 0xC0, 0x7F>>), nil)

    assert value == {:nonfinite, 0x7FC00000}
    assert Serialize.bits_processed(reader) == 32

    # and a re-encode reproduces the same bytes: the round trip preserves
    # all 32 bits
    {:ok, writer, _} = Serialize.serialize_float(WriteStream.new(), value)
    assert WriteStream.data(WriteStream.flush(writer)) == <<0x00, 0x00, 0xC0, 0x7F>>
  end

  test "finite floats round-trip exactly, including -0.0 and denormals by pattern" do
    for value <- [0.0, 1.0, -1.0, 3.5, Float32.round32!(3.1415926), 1.0e-38] do
      {:ok, writer, _} = Serialize.serialize_float(WriteStream.new(), value)
      writer = WriteStream.flush(writer)

      {:ok, _reader, decoded} =
        Serialize.serialize_float(ReadStream.new(WriteStream.data(writer)), nil)

      assert Float32.bits32(decoded) == Float32.bits32(value)
    end

    for value <- [0.0, 1.0 / 3.0, -1.0, 5.0e-324, 1.7976931348623157e308] do
      {:ok, writer, _} = Serialize.serialize_double(WriteStream.new(), value)
      writer = WriteStream.flush(writer)

      {:ok, _reader, decoded} =
        Serialize.serialize_double(ReadStream.new(WriteStream.data(writer)), nil)

      assert Float32.bits64(decoded) == Float32.bits64(value)
    end
  end

  test "truncated reads refuse; the double's second group may already be consumed" do
    assert {:error, _} = Serialize.serialize_float(ReadStream.new(<<1, 2, 3>>), nil)

    {:error, reader} = Serialize.serialize_double(ReadStream.new(<<1, 2, 3, 4, 5>>), nil)
    assert Serialize.bits_processed(reader) == 32
  end

  test "caller misuse raises on write" do
    # a double too large for float32 cannot be written as a finite float
    assert_raise ArgumentError, fn -> Serialize.serialize_float(WriteStream.new(), 1.0e39) end
    # a finite pattern may not hide inside the non-finite carrier
    assert_raise ArgumentError, fn ->
      Serialize.serialize_float(WriteStream.new(), {:nonfinite, 0x3F800000})
    end
  end

  test "measure charges 32 and 64 bits exactly" do
    measure = MeasureStream.new()
    {:ok, measure, _} = Serialize.serialize_float(measure, 1.0)
    {:ok, measure, _} = Serialize.serialize_double(measure, 1.0)
    assert Serialize.bits_processed(measure) == 96
  end
end
