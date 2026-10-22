defmodule Serialize.CompressedFloatTest do
  use ExUnit.Case, async: true

  alias Serialize.{Float32, MeasureStream, ReadStream, WriteStream}

  # The nonzero-min conformance vector (serialize.h
  # test_compressed_float_conformance_nonzero_min): three values over
  # [-100,100] at resolution 0.01 (20000 steps, 15 bits each), then an
  # align. The decoded floats are pinned bit-exactly — the divergences this
  # vector detects are single ulps, and tolerance would hide them.
  @nonzero_min_pinned_bytes <<0x10, 0xA7, 0x06, 0x80, 0x82, 0x06>>
  @nonzero_min_values [0.0, -99.875, -33.34]
  @nonzero_min_patterns [0x00000000, 0xC2C7BD71, 0xC2055C2A]

  # The writer-fusion conformance vector (serialize.h
  # test_compressed_float_conformance_writer_fusion): [0, 16777215] at
  # resolution 1 — the band where the float32 ulp of the scaled product
  # reaches 1, and where the normative integer clamp lives.
  @writer_fusion_pinned_bytes <<0x00, 0x00, 0x80, 0xAC, 0xAA, 0xAA, 0xFF, 0xFF, 0xFF>>
  @writer_fusion_values [8_388_608.0, 11_184_811.0, 16_777_215.0]
  @writer_fusion_patterns [0x4B000000, 0x4B2AAAAC, 0x4B7FFFFF]

  defp serialize_three(stream, [a, b, c], min, max, res) do
    with {:ok, stream, a} <- Serialize.serialize_compressed_float(stream, a, min, max, res),
         {:ok, stream, b} <- Serialize.serialize_compressed_float(stream, b, min, max, res),
         {:ok, stream, c} <- Serialize.serialize_compressed_float(stream, c, min, max, res),
         {:ok, stream} <- Serialize.serialize_align(stream) do
      {:ok, stream, [a, b, c]}
    end
  end

  test "nonzero-min vector, write side: the two-rounding quantization produces the pinned bytes" do
    {:ok, writer, _} =
      serialize_three(WriteStream.new(), @nonzero_min_values, -100.0, 100.0, 0.01)

    writer = WriteStream.flush(writer)
    assert Serialize.bytes_processed(writer) == byte_size(@nonzero_min_pinned_bytes)
    assert WriteStream.data(writer) == @nonzero_min_pinned_bytes
  end

  test "nonzero-min vector, read side: the decoded bit patterns are pinned exactly" do
    reader = ReadStream.new(@nonzero_min_pinned_bytes)
    {:ok, _reader, decoded} = serialize_three(reader, [nil, nil, nil], -100.0, 100.0, 0.01)
    assert Enum.map(decoded, &Float32.bits32/1) == @nonzero_min_patterns
  end

  test "writer-fusion vector, write side: the clamp band's pinned bytes" do
    {:ok, writer, _} =
      serialize_three(WriteStream.new(), @writer_fusion_values, 0.0, 16_777_215.0, 1.0)

    writer = WriteStream.flush(writer)
    assert Serialize.bytes_processed(writer) == byte_size(@writer_fusion_pinned_bytes)
    assert WriteStream.data(writer) == @writer_fusion_pinned_bytes
  end

  test "writer-fusion vector, read side: the decoded bit patterns are pinned exactly" do
    reader = ReadStream.new(@writer_fusion_pinned_bytes)
    {:ok, _reader, decoded} = serialize_three(reader, [nil, nil, nil], 0.0, 16_777_215.0, 1.0)
    assert Enum.map(decoded, &Float32.bits32/1) == @writer_fusion_patterns
  end

  test "the integer clamp witnesses (STANDARD.md schema#109): both declared classes" do
    # [0, 8388609] at resolution 1: without the clamp the writer emits a
    # top-of-range code its own reader rejects
    {:ok, writer, _} =
      Serialize.serialize_compressed_float(WriteStream.new(), 8_388_609.0, 0.0, 8_388_609.0, 1.0)

    writer = WriteStream.flush(writer)

    {:ok, _reader, decoded} =
      Serialize.serialize_compressed_float(
        ReadStream.new(WriteStream.data(writer)),
        nil,
        0.0,
        8_388_609.0,
        1.0
      )

    assert Float32.bits32(decoded) == Float32.bits32(8_388_609.0)

    # [0, 16777215] at resolution 1: without the clamp the writer leaks a
    # 25th bit into a 24-bit field — the wire-divergence class
    {:ok, writer, _} =
      Serialize.serialize_compressed_float(
        WriteStream.new(),
        16_777_215.0,
        0.0,
        16_777_215.0,
        1.0
      )

    assert Serialize.bits_processed(writer) == 24
    writer = WriteStream.flush(writer)

    {:ok, _reader, decoded} =
      Serialize.serialize_compressed_float(
        ReadStream.new(WriteStream.data(writer)),
        nil,
        0.0,
        16_777_215.0,
        1.0
      )

    assert Float32.bits32(decoded) == Float32.bits32(16_777_215.0)
  end

  test "the between-quanta discriminators over [0,10] at 0.01 quantize as the standard states" do
    # STANDARD.md: the required arithmetic quantizes 0.005 -> 1, 0.025 -> 3,
    # 0.105 -> 11 and 9.995 -> 1000; widening to double yields 0, 2, 10, 999.
    for {value, expected_code} <- [{0.005, 1}, {0.025, 3}, {0.105, 11}, {9.995, 1000}, {2.5, 250}] do
      {:ok, writer, _} =
        Serialize.serialize_compressed_float(WriteStream.new(), value, 0.0, 10.0, 0.01)

      writer = WriteStream.flush(writer)

      {:ok, _reader, code} =
        Serialize.serialize_bits(ReadStream.new(WriteStream.data(writer)), nil, 10)

      assert code == expected_code, "#{value} quantized to #{code}, expected #{expected_code}"
    end
  end

  test "values clamp into the declared range on write" do
    for {value, expected_code} <- [{-5.0, 0}, {15.0, 1000}] do
      {:ok, writer, _} =
        Serialize.serialize_compressed_float(WriteStream.new(), value, 0.0, 10.0, 0.01)

      writer = WriteStream.flush(writer)

      {:ok, _reader, code} =
        Serialize.serialize_bits(ReadStream.new(WriteStream.data(writer)), nil, 10)

      assert code == expected_code
    end
  end

  test "the reader rejects an integer above the step count" do
    # [0,10] at 0.01: 1000 steps in a 10-bit field; the code 1001 fits the
    # field but not the declaration
    {:ok, writer, _} = Serialize.serialize_bits(WriteStream.new(), 1001, 10)
    data = WriteStream.data(WriteStream.flush(writer))

    {:error, reader} =
      Serialize.serialize_compressed_float(ReadStream.new(data), nil, 0.0, 10.0, 0.01)

    assert Serialize.refusal(reader) == :value_out_of_range
  end

  test "a truncated read refuses" do
    {:error, reader} =
      Serialize.serialize_compressed_float(ReadStream.new(<<0xFF>>), nil, 0.0, 10.0, 0.01)

    assert Serialize.refusal(reader) == :past_end
  end

  # [3 * 2^103, FLT_MAX] at resolution 2^104: delta and delta / res are
  # finite, and still the top integer, 2^24 - 2 in 24 bits, decodes to
  # min + delta, which rounds to 2^128: +inf
  @top_min 3.0 * :math.pow(2, 103)
  @top_max 3.4028234663852886e38
  @top_res :math.pow(2, 104)

  test "a decode that is not finite is refused, whatever the declaration" do
    {:error, reader} =
      Serialize.serialize_compressed_float(
        ReadStream.new(<<0xFE, 0xFF, 0xFF>>),
        nil,
        @top_min,
        @top_max,
        @top_res
      )

    assert Serialize.refusal(reader) == :non_finite_float

    # the integer one below the top decodes finite and is accepted
    {:ok, _reader, value} =
      Serialize.serialize_compressed_float(
        ReadStream.new(<<0xFD, 0xFF, 0xFF>>),
        nil,
        @top_min,
        @top_max,
        @top_res
      )

    assert Float32.bits32(value) == 0x7F7FFFFE
  end

  test "a declaration whose top decodes to an infinity raises on the write path only" do
    # non-conforming as a whole: even a value that would decode finite
    assert_raise ArgumentError, fn ->
      Serialize.serialize_compressed_float(
        WriteStream.new(),
        @top_min,
        @top_min,
        @top_max,
        @top_res
      )
    end

    assert_raise ArgumentError, fn ->
      Serialize.serialize_compressed_float(
        MeasureStream.new(),
        @top_min,
        @top_min,
        @top_max,
        @top_res
      )
    end
  end

  test "non-conforming declarations and values raise on write" do
    # min >= max
    assert_raise ArgumentError, fn ->
      Serialize.serialize_compressed_float(WriteStream.new(), 0.0, 10.0, 0.0, 0.01)
    end

    # res == 0
    assert_raise ArgumentError, fn ->
      Serialize.serialize_compressed_float(WriteStream.new(), 0.0, 0.0, 10.0, 0.0)
    end

    # delta not finite in float32
    assert_raise ArgumentError, fn ->
      Serialize.serialize_compressed_float(WriteStream.new(), 0.0, -3.0e38, 3.0e38, 0.01)
    end

    # a value that is not a number through compressed_float is
    # non-conforming
    assert_raise ArgumentError, fn ->
      Serialize.serialize_compressed_float(WriteStream.new(), :nan, 0.0, 10.0, 0.01)
    end
  end

  test "measure charges the exact field width" do
    measure = MeasureStream.new()
    {:ok, measure, _} = Serialize.serialize_compressed_float(measure, 5.0, 0.0, 10.0, 0.01)
    assert Serialize.bits_processed(measure) == 10
    {:ok, measure, _} = Serialize.serialize_compressed_float(measure, 0.0, -100.0, 100.0, 0.01)
    assert Serialize.bits_processed(measure) == 25
  end
end
