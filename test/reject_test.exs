defmodule Serialize.RejectTest do
  @moduledoc """
  The caller's refusal (STANDARD.md "Refusal reasons", `rejected`;
  IMPLEMENTING.md U2): `Serialize.serialize_reject/1` at the top level, and
  `Serialize.serialize_object/2` latching `:rejected` when the nested
  function refuses on its own. Both go through the stream's one latch, so
  the refusal is terminal and the first reason wins.
  """

  use ExUnit.Case, async: true

  alias Serialize.{MeasureStream, ReadStream, WriteStream}

  defp read_four_bits(stream), do: Serialize.serialize_bits(stream, 0, 4)

  test "rejected is the last reason of the closed list" do
    assert List.last(ReadStream.refusals()) == :rejected
  end

  describe "serialize_reject" do
    test "latches rejected on a read stream" do
      {:ok, stream, 5} = read_four_bits(ReadStream.new(<<0x05>>))
      assert {:error, stream} = Serialize.serialize_reject(stream)
      assert ReadStream.failed?(stream)
      assert Serialize.refusal(stream) == :rejected
      assert Serialize.bits_processed(stream) == 4
    end

    test "is terminal: every later read refuses and keeps rejected" do
      {:error, stream} = Serialize.serialize_reject(ReadStream.new(<<0xAB>>))
      assert {:error, stream} = Serialize.serialize_bits(stream, 0, 8)
      assert {:error, stream} = Serialize.serialize_int(stream, nil, 7, 7)
      assert {:error, stream} = Serialize.serialize_object(stream, &{:ok, &1})
      assert Serialize.bits_processed(stream) == 0
      assert Serialize.refusal(stream) == :rejected
    end

    test "keeps the first reason on a stream that already refused" do
      {:error, stream} = Serialize.serialize_bits(ReadStream.new(<<0xFF>>), 0, 16)
      assert {:error, stream} = Serialize.serialize_reject(stream)
      assert Serialize.refusal(stream) == :past_end
    end

    test "on a write or measure stream refuses without raising and changes nothing" do
      write = WriteStream.new()
      measure = MeasureStream.new()
      assert {:error, ^write} = Serialize.serialize_reject(write)
      assert {:error, ^measure} = Serialize.serialize_reject(measure)
    end
  end

  describe "ReadStream.fail" do
    test "a reason outside the closed list latches rejected, never none" do
      stream = ReadStream.fail(ReadStream.new(<<0>>), :not_a_reason)
      assert ReadStream.failed?(stream)
      assert Serialize.refusal(stream) == :rejected

      stream = ReadStream.fail(ReadStream.new(<<0>>), nil)
      assert Serialize.refusal(stream) == :rejected
    end
  end

  describe "serialize_object" do
    test "an accepted object returns its function's result and adds no bytes" do
      object = fn stream ->
        with {:ok, stream, a} <- Serialize.serialize_bits(stream, 0, 4),
             {:ok, stream, b} <- Serialize.serialize_bool(stream, false) do
          {:ok, stream, {a, b}}
        end
      end

      assert {:ok, stream, {10, true}} =
               Serialize.serialize_object(ReadStream.new(<<0x1A>>), object)

      assert Serialize.bits_processed(stream) == 5
      assert Serialize.refusal(stream) == nil
    end

    test "a function that returns failure on its own latches rejected" do
      object = fn stream ->
        {:ok, stream, _} = read_four_bits(stream)
        {:error, stream}
      end

      assert {:error, stream} = Serialize.serialize_object(ReadStream.new(<<0x05>>), object)
      assert Serialize.refusal(stream) == :rejected
      assert {:error, stream} = Serialize.serialize_bits(stream, 0, 1)
      assert Serialize.refusal(stream) == :rejected
    end

    test "an inner refusal keeps its reason through the object's failure" do
      object = fn stream ->
        case Serialize.serialize_bits(stream, 0, 16) do
          {:error, stream} -> {:error, stream}
          ok -> ok
        end
      end

      assert {:error, stream} = Serialize.serialize_object(ReadStream.new(<<0xFF>>), object)
      assert Serialize.refusal(stream) == :past_end
    end

    test "a function that swallows an inner refusal still refuses with its reason" do
      object = fn stream ->
        {:ok, stream, _} = Serialize.serialize_bits(stream, 0, 3)
        {:error, stream} = Serialize.serialize_align(stream)
        {:ok, stream}
      end

      assert {:error, stream} = Serialize.serialize_object(ReadStream.new(<<0xFD>>), object)
      assert Serialize.refusal(stream) == :nonzero_padding
    end

    test "on a refused stream refuses on entry without calling the function" do
      {:error, stream} = Serialize.serialize_reject(ReadStream.new(<<0xAB>>))
      object = fn _stream -> flunk("the object's function was called on a refused stream") end
      assert {:error, ^stream} = Serialize.serialize_object(stream, object)
    end

    test "on a write and a measure stream passes the function's result through" do
      object = fn stream -> Serialize.serialize_bits(stream, 5, 4) end

      assert {:ok, write, 5} = Serialize.serialize_object(WriteStream.new(), object)
      assert Serialize.bits_processed(write) == 4
      assert {:ok, measure, 5} = Serialize.serialize_object(MeasureStream.new(), object)
      assert Serialize.bits_processed(measure) == 4
    end
  end
end
