defmodule Serialize.FloatTest do
  use ExUnit.Case, async: true

  alias Serialize.{Float32, MeasureStream, ReadStream, WriteStream}

  # serialize.h golden_float_bytes / golden_float_patterns /
  # golden_double_patterns at format 2.0: the finite patterns a sanitizing
  # implementation breaks (a sign of zero flipped, a subnormal flushed),
  # compared by bits, never by value.
  @golden_float_bytes <<0x00, 0x00, 0x00, 0x80, 0x01, 0x00, 0x00, 0x00, 0xFF, 0xFF, 0x7F, 0x80,
                        0xFF, 0xFF, 0x7F, 0x7F, 0x00, 0x00, 0x80, 0x00, 0x01, 0x00, 0x00, 0x00,
                        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x80>>

  # -0.0, smallest subnormal, largest negative subnormal, largest finite,
  # smallest normal
  @golden_float_patterns [0x80000000, 0x00000001, 0x807FFFFF, 0x7F7FFFFF, 0x00800000]
  # f64 smallest subnormal, f64 -0.0
  @golden_double_patterns [0x0000000000000001, 0x8000000000000000]

  # the refused half: NaN with any payload or sign, signaling or quiet, and
  # both infinities (serialize.h non_finite_float_patterns and its double twin)
  @non_finite_float_patterns [
    0x7F800000,
    0xFF800000,
    0x7FC00000,
    0x7F800001,
    0x7FC00001,
    0xFFFFFFFF,
    0x7FFFFFFF,
    0xFFC00000,
    0x7FDEAD00
  ]
  @non_finite_double_patterns [
    0x7FF0000000000000,
    0xFFF0000000000000,
    0x7FF8000000000000,
    0x7FF0000000000001,
    0x7FF4000000000001,
    0xFFFFFFFFFFFFFFFF,
    0x7FFFFFFFFFFFFFFF,
    0xFFF8000000000000
  ]

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

  test "bit exactness: the golden finite patterns write exactly the pinned bytes" do
    floats = Enum.map(@golden_float_patterns, &Float32.value32/1)
    doubles = Enum.map(@golden_double_patterns, &Float32.value64/1)

    {:ok, writer, _f, _d} = serialize_golden_floats(WriteStream.new(), floats, doubles)
    writer = WriteStream.flush(writer)
    assert Serialize.bytes_processed(writer) == byte_size(@golden_float_bytes)
    assert WriteStream.data(writer) == @golden_float_bytes
  end

  test "bit exactness: the pinned bytes decode to the exact transmitted patterns" do
    reader = ReadStream.new(@golden_float_bytes)
    nils = List.duplicate(nil, 5)

    {:ok, _reader, floats, doubles} = serialize_golden_floats(reader, nils, [nil, nil])

    assert Enum.map(floats, &Float32.bits32/1) == @golden_float_patterns
    assert Enum.map(doubles, &Float32.bits64/1) == @golden_double_patterns
  end

  test "finite only: every NaN and infinity pattern is refused as non_finite_float" do
    for bits <- @non_finite_float_patterns do
      {:error, reader} =
        Serialize.serialize_float(ReadStream.new(<<bits::little-32>>), :untouched)

      assert Serialize.refusal(reader) == :non_finite_float,
             "float 0x#{Integer.to_string(bits, 16)}"

      # terminal: a further read refuses and keeps the first reason
      {:error, reader} = Serialize.serialize_bits(reader, 0, 1)
      assert Serialize.refusal(reader) == :non_finite_float
    end

    for bits <- @non_finite_double_patterns do
      {:error, reader} =
        Serialize.serialize_double(ReadStream.new(<<bits::little-64>>), :untouched)

      assert Serialize.refusal(reader) == :non_finite_float,
             "double 0x#{Integer.to_string(bits, 16)}"
    end
  end

  test "finite only: the refusal tests the exponent field and nothing else" do
    # the finite neighbours of the refused patterns are accepted: the
    # largest finite magnitude either side, and the exponent one below all
    # ones with every mantissa bit set
    for bits <- [0x7F7FFFFF, 0xFF7FFFFF, 0x7F000000, 0x00000000] do
      {:ok, _reader, value} = Serialize.serialize_float(ReadStream.new(<<bits::little-32>>), nil)
      assert Float32.bits32(value) == bits
    end

    for bits <- [0x7FEFFFFFFFFFFFFF, 0xFFEFFFFFFFFFFFFF, 0x7FE0000000000000] do
      {:ok, _reader, value} = Serialize.serialize_double(ReadStream.new(<<bits::little-64>>), nil)
      assert Float32.bits64(value) == bits
    end
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
    # a finite double too large for float32 narrows to an infinity, which
    # the wire does not carry: the check runs after the narrowing
    assert_raise ArgumentError, fn -> Serialize.serialize_float(WriteStream.new(), 1.0e39) end
    assert_raise ArgumentError, fn -> Serialize.serialize_float(WriteStream.new(), -1.0e39) end
    # the largest finite float32 itself is fine
    {:ok, _, _} = Serialize.serialize_float(WriteStream.new(), Float32.value32(0x7F7FFFFF))
    # the non-finite carrier of format 1.1 is gone
    assert_raise FunctionClauseError, fn ->
      Serialize.serialize_float(WriteStream.new(), {:nonfinite, 0x7FC00000})
    end

    assert_raise FunctionClauseError, fn ->
      Serialize.serialize_double(WriteStream.new(), {:nonfinite, 0x7FF0000000000000})
    end
  end

  test "measure charges 32 and 64 bits exactly" do
    measure = MeasureStream.new()
    {:ok, measure, _} = Serialize.serialize_float(measure, 1.0)
    {:ok, measure, _} = Serialize.serialize_double(measure, 1.0)
    assert Serialize.bits_processed(measure) == 96
  end
end
