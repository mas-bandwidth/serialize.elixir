defmodule Serialize.BytesStringTest do
  use ExUnit.Case, async: true

  alias Serialize.{MeasureStream, ReadStream, WriteStream}

  describe "serialize_bytes" do
    test "the zero-length pin: { bits(5,3); bytes(count 0); bits(0xA5,8) } is 0x05 0xA5" do
      # serialize.h test_golden_zero_length_bytes: the zero-length bytes
      # still aligns — the pad lands in bits [3,8) and 0xA5 occupies byte 1
      writer = WriteStream.new()
      {:ok, writer, _} = Serialize.serialize_bits(writer, 5, 3)
      {:ok, writer, _} = Serialize.serialize_bytes(writer, <<>>, 0)
      {:ok, writer, _} = Serialize.serialize_bits(writer, 0xA5, 8)
      writer = WriteStream.flush(writer)
      assert WriteStream.data(writer) == <<0x05, 0xA5>>

      reader = ReadStream.new(<<0x05, 0xA5>>)
      {:ok, reader, 5} = Serialize.serialize_bits(reader, nil, 3)
      {:ok, reader, <<>>} = Serialize.serialize_bytes(reader, nil, 0)
      {:ok, reader, 0xA5} = Serialize.serialize_bits(reader, nil, 8)
      assert Serialize.bytes_processed(reader) == 2
    end

    test "the unaligned pin: { bits(1,1); bytes(2); bits(0x0F,4) } is 0x01 0xEF 0xBE 0x0F" do
      # serialize.h test_golden_unaligned_bytes: the operation's own align
      # from bit index 1
      writer = WriteStream.new()
      {:ok, writer, _} = Serialize.serialize_bits(writer, 1, 1)
      {:ok, writer, _} = Serialize.serialize_bytes(writer, <<0xEF, 0xBE>>, 2)
      {:ok, writer, _} = Serialize.serialize_bits(writer, 0x0F, 4)
      writer = WriteStream.flush(writer)
      assert WriteStream.data(writer) == <<0x01, 0xEF, 0xBE, 0x0F>>

      reader = ReadStream.new(<<0x01, 0xEF, 0xBE, 0x0F>>)
      {:ok, reader, 1} = Serialize.serialize_bits(reader, nil, 1)
      {:ok, reader, <<0xEF, 0xBE>>} = Serialize.serialize_bytes(reader, nil, 2)
      {:ok, _reader, 0x0F} = Serialize.serialize_bits(reader, nil, 4)
    end

    test "the reader verifies the alignment padding is zero" do
      # bit 0 set plus non-zero pad bits: the align inside bytes refuses
      reader = ReadStream.new(<<0xFF, 0xEF>>)
      {:ok, reader, 1} = Serialize.serialize_bits(reader, nil, 1)
      assert {:error, _} = Serialize.serialize_bytes(reader, nil, 1)
    end

    test "a count beyond the remaining data refuses" do
      assert {:error, _} = Serialize.serialize_bytes(ReadStream.new(<<1, 2>>), nil, 3)
    end

    test "count mismatch raises on write" do
      assert_raise ArgumentError, fn ->
        Serialize.serialize_bytes(WriteStream.new(), <<1, 2>>, 3)
      end
    end

    test "measure charges the worst-case align plus the bytes" do
      measure = MeasureStream.new()
      {:ok, measure, _} = Serialize.serialize_bytes(measure, <<1, 2, 3>>, 3)
      assert Serialize.bits_processed(measure) == 7 + 24
    end
  end

  describe "serialize_string" do
    test "the zero-length pin: { bits(5,3); string(\"\", 8); bits(0xA5,8) } is 0x05 0xA5" do
      # serialize.h test_golden_zero_length_string: the empty string is a
      # 3-bit length of 0, then the zero-length payload's align pads [6,8)
      writer = WriteStream.new()
      {:ok, writer, _} = Serialize.serialize_bits(writer, 5, 3)
      {:ok, writer, _} = Serialize.serialize_string(writer, "", 8)
      {:ok, writer, _} = Serialize.serialize_bits(writer, 0xA5, 8)
      writer = WriteStream.flush(writer)
      assert WriteStream.data(writer) == <<0x05, 0xA5>>

      reader = ReadStream.new(<<0x05, 0xA5>>)
      {:ok, reader, 5} = Serialize.serialize_bits(reader, nil, 3)
      {:ok, reader, ""} = Serialize.serialize_string(reader, nil, 8)
      {:ok, _reader, 0xA5} = Serialize.serialize_bits(reader, nil, 8)
    end

    test "round-trips, and the bytes depend on buffer_size" do
      for {value, buffer_size} <- [{"golden", 16}, {"golden", 7}, {"", 2}, {"héllo", 32}] do
        {:ok, writer, ^value} = Serialize.serialize_string(WriteStream.new(), value, buffer_size)
        writer = WriteStream.flush(writer)
        reader = ReadStream.new(WriteStream.data(writer))
        {:ok, _reader, decoded} = Serialize.serialize_string(reader, nil, buffer_size)
        assert decoded == value
      end

      # the same string against different buffer sizes produces different
      # bytes: after a 3-bit prefix, a 6-bit length field pushes the
      # payload's align past the first byte where a 3-bit field does not
      prefix = fn buffer_size ->
        writer = WriteStream.new()
        {:ok, writer, _} = Serialize.serialize_bits(writer, 7, 3)
        {:ok, writer, _} = Serialize.serialize_string(writer, "golden", buffer_size)
        WriteStream.data(WriteStream.flush(writer))
      end

      assert prefix.(64) != prefix.(7)
    end

    test "an interior NUL fails the read" do
      # write the payload through serialize_bytes so the wire is doctored,
      # then read it as a string: length 3, bytes "a\\0b"
      writer = WriteStream.new()
      {:ok, writer, _} = Serialize.serialize_int(writer, 3, 0, 15)
      {:ok, writer, _} = Serialize.serialize_bytes(writer, <<?a, 0, ?b>>, 3)
      data = WriteStream.data(WriteStream.flush(writer))
      assert {:error, _} = Serialize.serialize_string(ReadStream.new(data), nil, 16)
    end

    test "invalid UTF-8 fails the read" do
      for payload <- [
            # stray continuation byte
            <<0x80>>,
            # overlong two-byte encoding of '/'
            <<0xC0, 0xAF>>,
            # surrogate code point U+D800
            <<0xED, 0xA0, 0x80>>,
            # above U+10FFFF
            <<0xF4, 0x90, 0x80, 0x80>>,
            # truncated sequence
            <<0xE2, 0x82>>
          ] do
        writer = WriteStream.new()
        {:ok, writer, _} = Serialize.serialize_int(writer, byte_size(payload), 0, 15)
        {:ok, writer, _} = Serialize.serialize_bytes(writer, payload, byte_size(payload))
        data = WriteStream.data(WriteStream.flush(writer))

        assert {:error, _} = Serialize.serialize_string(ReadStream.new(data), nil, 16),
               "payload #{inspect(payload)} was not refused"
      end
    end

    test "a length above the range refuses" do
      # buffer_size 11 prices the length in 4 bits over [0,10]; the code 11
      # fits the field but not the range
      writer = WriteStream.new()
      {:ok, writer, _} = Serialize.serialize_bits(writer, 11, 4)
      data = WriteStream.data(WriteStream.flush(writer))
      assert {:error, _} = Serialize.serialize_string(ReadStream.new(data), nil, 11)
    end

    test "a truncated payload refuses" do
      writer = WriteStream.new()
      {:ok, writer, _} = Serialize.serialize_int(writer, 9, 0, 15)
      data = WriteStream.data(WriteStream.flush(writer))
      assert {:error, _} = Serialize.serialize_string(ReadStream.new(data), nil, 16)
    end

    test "a string that does not fit raises on write" do
      assert_raise ArgumentError, fn ->
        Serialize.serialize_string(WriteStream.new(), "golden", 6)
      end
    end

    test "measure charges the length field, the worst-case align and the bytes" do
      measure = MeasureStream.new()
      {:ok, measure, _} = Serialize.serialize_string(measure, "golden", 16)
      assert Serialize.bits_processed(measure) == 4 + 7 + 48
    end
  end

  describe "serialize_wstring" do
    test "the worked example: \"мир\" in a wide buffer of 8 is the 13-byte run" do
      # STANDARD.md "Worked Example": 3-bit length, then three 32-bit
      # groups, no alignment anywhere in the operation
      writer = WriteStream.new()
      {:ok, writer, _} = Serialize.serialize_wstring(writer, "мир", 8)
      {:ok, writer} = Serialize.serialize_align(writer)
      writer = WriteStream.flush(writer)

      assert WriteStream.data(writer) ==
               <<0xE3, 0x21, 0x00, 0x00, 0xC0, 0x21, 0x00, 0x00, 0x00, 0x22, 0x00, 0x00, 0x00>>

      assert Serialize.bits_processed(writer) == 104
    end

    test "round-trips BMP and astral text; an astral code point is two groups" do
      for {value, buffer_size, units} <- [
            {"мир", 8, 3},
            {"", 2, 0},
            {"ascii", 16, 5},
            # U+1D11E musical symbol: a surrogate pair on the wire
            {"a𝄞b", 8, 4}
          ] do
        {:ok, writer, ^value} = Serialize.serialize_wstring(WriteStream.new(), value, buffer_size)

        expected_bits =
          Serialize.Bits.bits_required(0, buffer_size - 1) + 32 * units

        assert Serialize.bits_processed(writer) == expected_bits

        writer = WriteStream.flush(writer)
        reader = ReadStream.new(WriteStream.data(writer))
        {:ok, _reader, decoded} = Serialize.serialize_wstring(reader, nil, buffer_size)
        assert decoded == value
      end
    end

    test "malformed payloads fail the read: every refusal rule" do
      # each case writes a doctored group sequence under a 3-bit length
      doctored = fn length, groups ->
        writer = WriteStream.new()
        {:ok, writer, _} = Serialize.serialize_int(writer, length, 0, 7)

        writer =
          Enum.reduce(groups, writer, fn group, writer ->
            {:ok, writer, _} = Serialize.serialize_bits(writer, group, 32)
            writer
          end)

        WriteStream.data(WriteStream.flush(writer))
      end

      refusals = [
        # a group above 0xFFFF is not a UTF-16 code unit
        {1, [0x10000]},
        # an interior NUL group: the two-lengths smuggling primitive
        {2, [0x41, 0x0000]},
        # a high surrogate without its low
        {2, [0xD800, 0x41]},
        # a low surrogate with no high before it
        {1, [0xDC00]},
        # a dangling high surrogate as the final group
        {1, [0xD800]}
      ]

      for {length, groups} <- refusals do
        data = doctored.(length, groups)

        assert {:error, _} = Serialize.serialize_wstring(ReadStream.new(data), nil, 8),
               "groups #{inspect(groups)} were not refused"
      end

      # and the well-formed pair passes: it is how astral text travels
      data = doctored.(2, [0xD834, 0xDD1E])
      {:ok, _reader, decoded} = Serialize.serialize_wstring(ReadStream.new(data), nil, 8)
      assert decoded == "𝄞"
    end

    test "a truncated payload refuses" do
      writer = WriteStream.new()
      {:ok, writer, _} = Serialize.serialize_int(writer, 3, 0, 7)
      {:ok, writer, _} = Serialize.serialize_bits(writer, 0x41, 32)
      data = WriteStream.data(WriteStream.flush(writer))
      assert {:error, _} = Serialize.serialize_wstring(ReadStream.new(data), nil, 8)
    end

    test "a wstring that does not fit its buffer raises on write" do
      # 4 units < buffer_size must hold: "a𝄞b" is 4 units
      assert_raise ArgumentError, fn ->
        Serialize.serialize_wstring(WriteStream.new(), "a𝄞b", 4)
      end
    end

    test "measure charges the length field plus 32 bits per unit, no align" do
      measure = MeasureStream.new()
      {:ok, measure, _} = Serialize.serialize_wstring(measure, "мир", 8)
      assert Serialize.bits_processed(measure) == 3 + 96
    end
  end
end
