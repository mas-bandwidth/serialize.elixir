defmodule Serialize.TerminalTest do
  @moduledoc """
  Failure is terminal, and a refused read writes no destination
  (STANDARD.md, Reader Obligations).

  This port takes the **latch** shape: a `ReadStream` survives a refusal,
  so it carries a `failed` flag that the first refusal sets, and every
  later read on that stream refuses without consuming bits. Each test
  below fails a stream one way, then proves that a read which would
  otherwise succeed on the bytes still refuses.
  """

  use ExUnit.Case, async: true

  alias Serialize.{ReadStream, WriteStream}

  # a read that the remaining bytes would satisfy on an unfailed stream
  defp valid_read(stream), do: Serialize.serialize_bits(stream, 0, 1)

  test "a failure before any consumption is terminal" do
    # 8 bits of data, a 32-bit read: refused, consuming nothing
    {:error, stream} = Serialize.serialize_bits(ReadStream.new(<<0xFF>>), 0, 32)
    assert ReadStream.failed?(stream)
    assert Serialize.bits_processed(stream) == 0
    assert {:error, _} = valid_read(stream)
  end

  test "a failure after partial consumption is terminal" do
    {:ok, stream, _} = Serialize.serialize_bits(ReadStream.new(<<0xFF, 0xFF>>), 0, 4)
    {:error, stream} = Serialize.serialize_bits(stream, 0, 32)
    assert ReadStream.failed?(stream)
    assert {:error, _} = valid_read(stream)
  end

  test "a failure on range headroom is terminal" do
    # 8 bits carry 255, above the range [0, 200]
    {:error, stream} = Serialize.serialize_int(ReadStream.new(<<0xFF, 0x00>>), nil, 0, 200)
    assert ReadStream.failed?(stream)
    assert {:error, _} = valid_read(stream)
  end

  test "a failure on alignment padding is terminal" do
    # one bit read, then an align whose seven padding bits are not zero
    {:ok, stream, _} = Serialize.serialize_bits(ReadStream.new(<<0xFF, 0x00>>), 0, 1)
    {:error, stream} = Serialize.serialize_align(stream)
    assert ReadStream.failed?(stream)
    assert {:error, _} = valid_read(stream)
  end

  test "a failure on a malformed string is terminal" do
    {:ok, writer, _} = Serialize.serialize_string(WriteStream.new(), "abc", 16)
    <<head::binary-size(1), _payload_byte, tail::binary>> = WriteStream.data(writer)

    # 0xFF is not a UTF-8 lead byte; the trailing byte leaves the stream
    # bits a later read could otherwise consume
    data = head <> <<0xFF>> <> tail <> <<0x00>>

    {:error, stream} = Serialize.serialize_string(ReadStream.new(data), nil, 16)
    assert ReadStream.failed?(stream)
    assert {:error, _} = valid_read(stream)
  end

  test "a failure on int_relative is terminal" do
    # previous at the top of the domain, the one-bit tier: the
    # reconstruction leaves the domain and the read is refused
    {:error, stream} =
      Serialize.serialize_int_relative(ReadStream.new(<<0x01, 0x00>>), 0x7FFFFFFF, nil)

    assert ReadStream.failed?(stream)
    assert {:error, _} = valid_read(stream)
  end

  test "every read operation refuses on a failed stream" do
    {:error, stream} = Serialize.serialize_bits(ReadStream.new(<<0xFF>>), 0, 32)

    assert {:error, _} = Serialize.serialize_bits(stream, 0, 1)
    assert {:error, _} = Serialize.serialize_bool(stream, nil)
    assert {:error, _} = Serialize.serialize_uint128(stream, nil)
    assert {:error, _} = Serialize.serialize_int(stream, nil, 0, 1)
    assert {:error, _} = Serialize.serialize_int64(stream, nil, 0, 1)
    assert {:error, _} = Serialize.serialize_int128(stream, nil, 0, 1)
    assert {:error, _} = Serialize.serialize_int_relative(stream, 0, nil)
    assert {:error, _} = Serialize.serialize_float(stream, nil)
    assert {:error, _} = Serialize.serialize_double(stream, nil)
    assert {:error, _} = Serialize.serialize_compressed_float(stream, nil, 0, 1, 0.01)
    assert {:error, _} = Serialize.serialize_align(stream)
    assert {:error, _} = Serialize.serialize_bytes(stream, nil, 1)
    assert {:error, _} = Serialize.serialize_string(stream, nil, 16)
    assert {:error, _} = Serialize.serialize_wstring(stream, nil, 16)
    assert {:error, _} = Serialize.serialize_fixed(stream, nil, 16, 16, -1, 1)
  end

  test "a zero-bit read refuses on a failed stream, at every operation that has one" do
    # STANDARD.md, Reader Obligations: "Every read consults the failure
    # state before it does anything else, zero-bit reads included, so a
    # degenerate ranged read, an align on an already aligned stream, a
    # bytes call of zero count and object all refuse on a stream that has
    # already failed." Each read below consumes nothing and would
    # otherwise always succeed, which is what a reader treating "consumes
    # no bits" as "cannot fail" gets wrong.
    {:error, stream} = Serialize.serialize_bits(ReadStream.new(<<0xFF>>), 0, 32)
    assert Serialize.align_bits(stream) == 0

    assert {:error, _} = Serialize.serialize_int(stream, nil, 7, 7)
    assert {:error, _} = Serialize.serialize_int64(stream, nil, 7, 7)
    assert {:error, _} = Serialize.serialize_int128(stream, nil, 7, 7)
    assert {:error, _} = Serialize.serialize_fixed(stream, nil, 16, 16, 7, 7)
    assert {:error, _} = Serialize.serialize_align(stream)
    assert {:error, _} = Serialize.serialize_bytes(stream, nil, 0)
  end

  test "a failed stream consumes no further bits" do
    {:ok, stream, _} = Serialize.serialize_bits(ReadStream.new(<<0xFF, 0xFF>>), 0, 4)
    {:error, stream} = Serialize.serialize_bits(stream, 0, 32)
    consumed = Serialize.bits_processed(stream)

    {:error, stream} = valid_read(stream)
    assert Serialize.bits_processed(stream) == consumed
  end

  test "a degenerate range refuses on a failed stream rather than yielding min" do
    # zero bits consume nothing and would otherwise always succeed; the
    # latch is checked before the width, so this refuses too
    {:error, stream} = Serialize.serialize_bits(ReadStream.new(<<0xFF>>), 0, 32)
    assert {:error, _} = Serialize.serialize_int128(stream, nil, 7, 7)
  end

  test "a degenerate fixed point range refuses on a failed stream rather than yielding raw min" do
    # the fixed point codec is the ranged integer codec over the raw
    # bounds, so a degenerate Q format meets the same latch as a
    # degenerate int at every storage width
    {:error, stream} = Serialize.serialize_bits(ReadStream.new(<<0xFF>>), 0, 32)

    assert {:error, _} = Serialize.serialize_fixed(stream, nil, 8, 8, 3, 3)
    assert {:error, _} = Serialize.serialize_fixed(stream, nil, 16, 16, 7, 7)
    assert {:error, _} = Serialize.serialize_fixed(stream, nil, 64, 64, 0, 0)
  end

  test "re-initialization clears the failure" do
    {:error, stream} = Serialize.serialize_bits(ReadStream.new(<<0xFF>>), 0, 32)
    assert ReadStream.failed?(stream)

    fresh = ReadStream.new(<<0xFF>>)
    refute ReadStream.failed?(fresh)
    assert {:ok, _stream, 1} = Serialize.serialize_bits(fresh, 0, 1)
  end

  test "a refused read hands back no value at all" do
    # the non-mutation rule is structural here: a refusal is the two-tuple
    # `{:error, stream}`, so there is no decoded value for a caller to
    # mistake for one, and the caller's own binding is untouched
    value = :untouched
    result = Serialize.serialize_int(ReadStream.new(<<0xFF>>), value, 0, 200)

    assert {:error, _stream} = result
    refute match?({:ok, _, _}, result)
    assert value == :untouched
  end
end
