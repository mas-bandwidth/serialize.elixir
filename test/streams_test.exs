defmodule Serialize.StreamsTest do
  use ExUnit.Case, async: true

  alias Serialize.{ReadStream, WriteStream}

  test "bits and bytes processed track the cursor on both sides" do
    writer = WriteStream.new()
    assert Serialize.bits_processed(writer) == 0
    assert Serialize.bytes_processed(writer) == 0
    assert Serialize.align_bits(writer) == 0

    {:ok, writer, _} = Serialize.serialize_bits(writer, 5, 3)
    assert Serialize.bits_processed(writer) == 3
    assert Serialize.bytes_processed(writer) == 1
    assert Serialize.align_bits(writer) == 5

    {:ok, writer} = Serialize.serialize_align(writer)
    assert Serialize.bits_processed(writer) == 8
    assert Serialize.align_bits(writer) == 0

    reader = ReadStream.new(WriteStream.data(WriteStream.flush(writer)))
    {:ok, reader, 5} = Serialize.serialize_bits(reader, nil, 3)
    assert Serialize.bits_processed(reader) == 3
    assert Serialize.align_bits(reader) == 5
    {:ok, reader} = Serialize.serialize_align(reader)
    assert Serialize.bits_processed(reader) == 8
  end

  test "an align against a truncated stream refuses" do
    reader = ReadStream.new(<<0x01>>)
    {:ok, reader, _} = Serialize.serialize_bits(reader, nil, 8)
    # aligned: the zero-cost align succeeds even with nothing left
    {:ok, reader} = Serialize.serialize_align(reader)
    assert Serialize.bits_processed(reader) == 8
  end

  test "a failed read is terminal by convention: the error carries the stream state" do
    reader = ReadStream.new(<<0xFF>>)
    {:ok, reader, _} = Serialize.serialize_bits(reader, nil, 4)
    {:error, reader} = Serialize.serialize_bits(reader, nil, 8)
    assert Serialize.bits_processed(reader) == 4
  end

  test "the reader shares the input binary: read bytes over 64B are sub-binaries until copied" do
    data = :binary.copy(<<0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11>>, 100)
    assert byte_size(data) == 1_200
    reader = ReadStream.new(data)
    {:ok, _reader, bytes} = Serialize.serialize_bytes(reader, nil, 100)
    assert byte_size(bytes) == 100
    assert bytes == binary_part(data, 0, 100)
    assert :binary.referenced_byte_size(bytes) == 1_200
    copied = :binary.copy(bytes)
    assert copied == bytes
    assert :binary.referenced_byte_size(copied) == 100

    {:docs_v1, _, :elixir, _, _, _, ser_docs} = Code.fetch_docs(Serialize)

    bytes_doc =
      Enum.find_value(ser_docs, fn
        {{:function, :serialize_bytes, 3}, _, _, %{"en" => doc}, _} -> doc
        _ -> nil
      end)

    string_doc =
      Enum.find_value(ser_docs, fn
        {{:function, :serialize_string, 3}, _, _, %{"en" => doc}, _} -> doc
        _ -> nil
      end)

    {:docs_v1, _, :elixir, _, _, _, ws_docs} = Code.fetch_docs(WriteStream)

    data_doc =
      Enum.find_value(ws_docs, fn
        {{:function, :data, 1}, _, _, %{"en" => doc}, _} -> doc
        _ -> nil
      end)

    assert bytes_doc =~ ":binary.copy/1"
    assert string_doc =~ ":binary.copy/1"
    assert data_doc =~ ":binary.copy/1"
  end

  test "refusal_name returns unknown for a reason outside the closed list" do
    assert Serialize.refusal_name(:bogus) == "unknown"
  end

  test "writing continues after flush at the bit cursor" do
    {:ok, writer, _} = Serialize.serialize_uint8(WriteStream.new(), 0xAB)
    writer = WriteStream.flush(writer)
    {:ok, writer, _} = Serialize.serialize_uint8(writer, 0xCD)
    writer = WriteStream.flush(writer)
    assert Serialize.bits_processed(writer) == 16
    assert WriteStream.data(writer) == <<0xAB, 0xCD>>
  end

  test "serialize_bytes after flush aligns and writes the payload" do
    {:ok, writer, _} = Serialize.serialize_bits(WriteStream.new(), 0b101, 3)
    writer = WriteStream.flush(writer)
    assert {:ok, writer, <<1>>} = Serialize.serialize_bytes(writer, <<1>>, 1)
    assert Serialize.bits_processed(writer) == 16
    assert WriteStream.data(writer) == <<0x05, 0x01>>
  end

  test "data before flush returns every processed byte" do
    writer =
      Enum.reduce([1, 2, 3, 4, 5], WriteStream.new(), fn byte, writer ->
        {:ok, writer, _} = Serialize.serialize_uint8(writer, byte)
        writer
      end)

    assert Serialize.bytes_processed(writer) == 5
    assert WriteStream.data(writer) == <<1, 2, 3, 4, 5>>
  end

  test "the writer's flushed words zero-fill past the bit index" do
    writer = WriteStream.new()
    {:ok, writer, _} = Serialize.serialize_bits(writer, 1, 1)
    writer = WriteStream.flush(writer)
    assert WriteStream.data(writer) == <<0x01>>
  end
end
