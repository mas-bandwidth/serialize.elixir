defmodule Serialize.CopyStringTest do
  @moduledoc """
  `Serialize.serialize_copy_string/2` (IMPLEMENTING.md U15,
  "`serialize_copy_string`"): the bytes before the first NUL, cut to
  `dest_size - 1` and backed off to a whole character. Elixir strings are
  values, so the helper returns the prefix. The vectors are the reference's
  test_copy_string; a binary holds any bytes, so the two ill-formed vectors
  are kept.
  """

  use ExUnit.Case, async: true

  alias Serialize.{MeasureStream, ReadStream, WriteStream}

  defp runtime(value), do: :erlang.binary_to_term(:erlang.term_to_binary(value))

  @vectors [
    {"abc", 8, "abc"},
    {<<"a", 0, "bc">>, 8, "a"},
    {"abcdefghij", 4, "abc"},
    {<<0xC3, 0xA9, 0xC3, 0xA9>>, 4, <<0xC3, 0xA9>>},
    {<<0xC3, 0xA9, 0xC3, 0xA9>>, 3, <<0xC3, 0xA9>>},
    {<<"a", 0xF0, 0x9F, 0x98, 0x80>>, 3, "a"},
    {<<"a", 0xF0, 0x9F, 0x98, 0x80>>, 4, "a"},
    {<<"a", 0xF0, 0x9F, 0x98, 0x80>>, 5, "a"},
    {<<"a", 0xF0, 0x9F, 0x98, 0x80>>, 6, <<"a", 0xF0, 0x9F, 0x98, 0x80>>},
    {<<"ab", 0x80, 0x80>>, 4, "a"},
    {<<0xC3, 0xA9, 0xA9, 0xA9>>, 4, ""},
    {"abc", 1, ""}
  ]

  test "the reference's test_copy_string vectors" do
    for {source, dest_size, expected} <- @vectors do
      assert Serialize.serialize_copy_string(source, dest_size) == expected,
             "copy_string(#{inspect(source)}, #{dest_size})"
    end
  end

  test "a copy of well-formed text is accepted by serialize_string at buffer_size dest_size" do
    source = "héllo wörld 😀 ok"

    for dest_size <- 1..(byte_size(source) + 2),
        stream <- [WriteStream.new(), MeasureStream.new()] do
      copy = Serialize.serialize_copy_string(source, dest_size)
      assert String.valid?(copy)
      assert byte_size(copy) <= dest_size - 1
      assert {:ok, _, ^copy} = Serialize.serialize_string(stream, copy, dest_size)
    end

    {:ok, writer, _} =
      Serialize.serialize_string(WriteStream.new(), Serialize.serialize_copy_string(source, 9), 9)

    data = WriteStream.data(WriteStream.flush(writer))
    assert {:ok, _, "héllo w"} = Serialize.serialize_string(ReadStream.new(data), nil, 9)
  end

  test "dest_size below 1, or not an integer, is write misuse and raises ArgumentError (U9)" do
    for dest_size <- [0, -1, 1.5, nil, :x] do
      assert_raise ArgumentError, fn ->
        Serialize.serialize_copy_string("abc", runtime(dest_size))
      end
    end
  end

  test "a source that is not a binary raises ArgumentError" do
    for source <- [nil, 5, ~c"abc"] do
      assert_raise ArgumentError, fn -> Serialize.serialize_copy_string(runtime(source), 8) end
    end
  end
end
