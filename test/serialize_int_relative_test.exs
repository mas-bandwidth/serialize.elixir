defmodule Serialize.IntRelativeTest do
  use ExUnit.Case, async: true

  alias Serialize.{MeasureStream, ReadStream, WriteStream}

  defp round_trip(previous, current) do
    {:ok, writer, ^current} =
      Serialize.serialize_int_relative(WriteStream.new(), previous, current)

    writer = WriteStream.flush(writer)
    reader = ReadStream.new(WriteStream.data(writer))
    {:ok, reader, decoded} = Serialize.serialize_int_relative(reader, previous, nil)
    {decoded, Serialize.bits_processed(writer), Serialize.bits_processed(reader)}
  end

  test "every tier boundary round-trips at its exact cost" do
    # {difference, total wire bits}: flags plus payload per the ladder
    cases = [
      {1, 1},
      {2, 2 + 3},
      {6, 2 + 3},
      {7, 3 + 5},
      {23, 3 + 5},
      {24, 4 + 9},
      {280, 4 + 9},
      {281, 5 + 13},
      {2000, 5 + 13},
      {4377, 5 + 13},
      {4378, 6 + 17},
      {69_914, 6 + 17},
      {69_915, 6 + 32},
      {1_000_000_000, 6 + 32}
    ]

    for {difference, bits} <- cases do
      previous = 100
      current = previous + difference
      {decoded, written, read} = round_trip(previous, current)
      assert decoded == current, "difference #{difference}"
      assert written == bits, "difference #{difference}: wrote #{written} bits, expected #{bits}"
      assert read == bits
    end
  end

  test "the final tier transmits current itself and the reader enforces the ordering" do
    # a stream carrying six zero flags then a 32-bit current <= previous
    # must refuse: the absolute form carries no ordering guarantee
    writer = WriteStream.new()
    {:ok, writer, _} = Serialize.serialize_bits(writer, 0, 6)
    {:ok, writer, _} = Serialize.serialize_bits(writer, 100, 32)
    data = WriteStream.data(WriteStream.flush(writer))

    assert {:error, _} = Serialize.serialize_int_relative(ReadStream.new(data), 100, nil)
    assert {:error, _} = Serialize.serialize_int_relative(ReadStream.new(data), 101, nil)
    {:ok, _reader, 100} = Serialize.serialize_int_relative(ReadStream.new(data), 99, nil)
  end

  test "a tier payload outside its band refuses" do
    # flags 0,1 select the [2,6] tier with a 3-bit payload; the code 5 + 2
    # = 7 exceeds the band
    writer = WriteStream.new()
    {:ok, writer, _} = Serialize.serialize_bits(writer, 0b10, 2)
    {:ok, writer, _} = Serialize.serialize_bits(writer, 0b111, 3)
    data = WriteStream.data(WriteStream.flush(writer))
    assert {:error, _} = Serialize.serialize_int_relative(ReadStream.new(data), 100, nil)
  end

  test "truncated streams refuse at every stage of the ladder" do
    assert {:error, _} = Serialize.serialize_int_relative(ReadStream.new(<<>>), 100, nil)

    # six zero flags then nothing: the 32-bit read refuses
    writer = WriteStream.new()
    {:ok, writer, _} = Serialize.serialize_bits(writer, 0, 6)
    data = WriteStream.data(WriteStream.flush(writer))
    assert {:error, _} = Serialize.serialize_int_relative(ReadStream.new(data), 100, nil)
  end

  test "the semantics are pinned: positive only, strictly increasing, no wrapping" do
    assert_raise ArgumentError, fn ->
      Serialize.serialize_int_relative(WriteStream.new(), 100, 100)
    end

    assert_raise ArgumentError, fn ->
      Serialize.serialize_int_relative(WriteStream.new(), 100, 99)
    end

    assert_raise FunctionClauseError, fn ->
      Serialize.serialize_int_relative(WriteStream.new(), -1, 5)
    end

    assert_raise ArgumentError, fn ->
      Serialize.serialize_int_relative(WriteStream.new(), 0, 0x1_0000_0000)
    end
  end

  test "measure charges the write path's exact ladder cost" do
    measure = MeasureStream.new()
    {:ok, measure, _} = Serialize.serialize_int_relative(measure, 100, 101)
    assert Serialize.bits_processed(measure) == 1
    {:ok, measure, _} = Serialize.serialize_int_relative(measure, 100, 2100)
    assert Serialize.bits_processed(measure) == 1 + 18
  end
end
