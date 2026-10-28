defmodule Serialize.UniformRulesTest do
  @moduledoc """
  IMPLEMENTING.md "Uniform behaviour: U1 to U16", the rules this port broke
  before 2.1, each cited by number. U2 is `Serialize.RejectTest`.

  This port's write-misuse mechanism (U9) is `ArgumentError`, raised on the
  write and the measure stream alike (U6). On a read stream every caller
  declaration that is not valid refuses as `:value_out_of_range` before any
  bits move, and never raises (U7, U16).
  """

  use ExUnit.Case, async: true

  import Bitwise

  alias Serialize.{MeasureStream, ReadStream, WriteStream}

  @big Integer.pow(2, 200)
  @huge Integer.pow(2, 1100)

  # The value is laundered through the term codec so the compiler's type
  # check cannot see it: these calls are misuse on purpose.
  defp runtime(value), do: :erlang.binary_to_term(:erlang.term_to_binary(value))

  defp writers, do: [WriteStream.new(), MeasureStream.new()]

  # A read refusal from a caller declaration: refused, out of range, and the
  # cursor never moved.
  defp assert_declaration_refused(result) do
    assert {:error, stream} = result
    assert Serialize.refusal(stream) == :value_out_of_range
    assert Serialize.bits_processed(stream) == 0
  end

  defp reader, do: ReadStream.new(<<0::256>>)

  describe "U5: int bounds are int32" do
    test "a bound outside int32 raises ArgumentError on write and measure" do
      for stream <- writers() do
        assert_raise ArgumentError, fn ->
          Serialize.serialize_int(stream, 5, 0, runtime(0x80000000))
        end

        assert_raise ArgumentError, fn ->
          Serialize.serialize_int(stream, 0, runtime(-0x80000001), 0)
        end
      end
    end

    test "a bound outside int32 refuses on read" do
      assert_declaration_refused(Serialize.serialize_int(reader(), nil, 0, runtime(0xFFFFFFFF)))
      assert_declaration_refused(Serialize.serialize_int(reader(), nil, runtime(@big), 0))
    end
  end

  describe "U6: a measure stream is held to the writer's contract" do
    test "values that do not fit their field raise as on write" do
      cases = [
        fn s -> Serialize.serialize_uint8(s, runtime(@big)) end,
        fn s -> Serialize.serialize_uint8(s, runtime(-1)) end,
        fn s -> Serialize.serialize_bits(s, runtime(@big), 40) end,
        fn s -> Serialize.serialize_int(s, runtime(999), 0, 100) end,
        fn s -> Serialize.serialize_int(s, runtime(:x), 0, 100) end,
        fn s -> Serialize.serialize_int64(s, runtime(@big), 0, 10) end,
        fn s -> Serialize.serialize_int128(s, runtime(@big), 0, 10) end,
        fn s -> Serialize.serialize_fixed(s, runtime(@big), 8, 8, 0, 10) end,
        fn s -> Serialize.serialize_bytes(s, "abc", runtime(1000)) end,
        fn s -> Serialize.serialize_bytes(s, runtime(nil), runtime(-5)) end
      ]

      for operation <- cases, stream <- writers() do
        assert_raise ArgumentError, fn -> operation.(stream) end
      end
    end

    test "a measure never goes negative" do
      measure = MeasureStream.new()
      assert_raise ArgumentError, fn -> Serialize.serialize_bytes(measure, nil, runtime(-5)) end
      assert Serialize.bits_processed(measure) == 0
    end
  end

  describe "U7 and U16: a reader never traps on a caller declaration" do
    test "a bits count outside [1, 64] refuses" do
      for bits <- [0, 65, -1, :x] do
        assert_declaration_refused(Serialize.serialize_bits(reader(), nil, runtime(bits)))
      end
    end

    test "a ranged min above its max refuses at every width" do
      assert_declaration_refused(Serialize.serialize_int(reader(), nil, 10, runtime(0)))
      assert_declaration_refused(Serialize.serialize_int64(reader(), nil, 10, runtime(0)))
      assert_declaration_refused(Serialize.serialize_int128(reader(), nil, 10, runtime(0)))

      assert_declaration_refused(
        Serialize.serialize_int64(reader(), nil, 0, runtime(0xFFFFFFFFFFFFFFFF))
      )

      assert_declaration_refused(Serialize.serialize_int128(reader(), nil, 0, runtime(@big)))
    end

    test "a string buffer_size below 1 refuses" do
      for size <- [0, -1, :x] do
        assert_declaration_refused(Serialize.serialize_string(reader(), nil, runtime(size)))
      end
    end

    test "a bytes count that is not a non-negative integer refuses" do
      assert_declaration_refused(Serialize.serialize_bytes(reader(), nil, runtime(:x)))
      assert_declaration_refused(Serialize.serialize_bytes(reader(), nil, runtime(-5)))
    end

    test "a fixed point declaration that does not fit its Q format refuses" do
      assert_declaration_refused(Serialize.serialize_fixed(reader(), nil, 8, 9, -100, 100))
      assert_declaration_refused(Serialize.serialize_fixed(reader(), nil, 8, 8, -200, 100))
      assert_declaration_refused(Serialize.serialize_fixed(reader(), nil, 8, 8, 10, runtime(0)))
    end

    test "an int_relative previous outside the domain refuses" do
      for previous <- [-1, 0x80000000, :x] do
        assert_declaration_refused(
          Serialize.serialize_int_relative(reader(), runtime(previous), nil)
        )
      end
    end

    test "a compressed_float declaration that is not finite or not ordered refuses" do
      for {min, max, res} <- [
            {0.0, @huge, 0.01},
            {-@huge, 0.0, 0.01},
            {0.0, 10.0, @huge},
            {10.0, 0.0, 0.01},
            {0.0, 10.0, 0.0},
            {0.0, 1.0e39, 0.01},
            {-3.0e38, 3.0e38, 0.01},
            {:x, 10.0, 0.01}
          ] do
        assert_declaration_refused(
          Serialize.serialize_compressed_float(
            reader(),
            nil,
            runtime(min),
            runtime(max),
            runtime(res)
          )
        )
      end
    end

    test "a stream that already refused keeps its first reason" do
      {:error, failed} = Serialize.serialize_bits(ReadStream.new(<<>>), nil, 8)
      assert {:error, failed} = Serialize.serialize_bits(failed, nil, runtime(0))
      assert {:error, failed} = Serialize.serialize_string(failed, nil, runtime(0))
      assert {:error, failed} = Serialize.serialize_int(failed, nil, 10, runtime(0))
      assert Serialize.refusal(failed) == :past_end
    end
  end

  describe "U9: one write-misuse mechanism, ArgumentError" do
    test "bad declarations on write and measure raise ArgumentError, never another exception" do
      cases = [
        fn s -> Serialize.serialize_bits(s, 0, runtime(0)) end,
        fn s -> Serialize.serialize_bits(s, 0, runtime(65)) end,
        fn s -> Serialize.serialize_int(s, 5, 10, runtime(0)) end,
        fn s -> Serialize.serialize_int64(s, 5, 10, runtime(0)) end,
        fn s -> Serialize.serialize_int128(s, 5, 10, runtime(0)) end,
        fn s -> Serialize.serialize_string(s, "", runtime(0)) end,
        fn s -> Serialize.serialize_int_relative(s, runtime(-1), 5) end,
        fn s -> Serialize.serialize_float(s, runtime(1)) end,
        fn s -> Serialize.serialize_double(s, runtime(1)) end,
        fn s -> Serialize.serialize_compressed_float(s, 1.0, 0.0, runtime(@huge), 0.01) end,
        fn s -> Serialize.serialize_compressed_float(s, 1.0, runtime(:x), 10.0, 0.01) end
      ]

      for operation <- cases, stream <- writers() do
        assert_raise ArgumentError, fn -> operation.(stream) end
      end
    end

    test "a compressed_float value too large for a double clamps like an infinity" do
      for stream <- writers() do
        assert {:ok, high, _} =
                 Serialize.serialize_compressed_float(stream, runtime(@huge), 0.0, 10.0, 0.01)

        assert {:ok, low, _} =
                 Serialize.serialize_compressed_float(stream, runtime(-@huge), 0.0, 10.0, 0.01)

        assert Serialize.bits_processed(high) == 10
        assert Serialize.bits_processed(low) == 10
      end

      {:ok, writer, _} =
        Serialize.serialize_compressed_float(WriteStream.new(), runtime(@huge), 0.0, 10.0, 0.01)

      data = WriteStream.data(WriteStream.flush(writer))

      assert {:ok, _, 10.0} =
               Serialize.serialize_compressed_float(ReadStream.new(data), nil, 0.0, 10.0, 0.01)
    end

    test "fail and reject on a write or measure stream return an error and never raise" do
      for stream <- writers() do
        assert {:error, ^stream} = Serialize.serialize_fail(stream, :past_end)
        assert {:error, ^stream} = Serialize.serialize_reject(stream)
      end
    end
  end

  describe "U4: string write checks UTF-8 and NUL" do
    test "a payload with a NUL or malformed UTF-8 raises on write and measure" do
      for value <- [<<"a", 0, "b">>, <<0xFF>>, <<0xED, 0xA0, 0x80>>], stream <- writers() do
        assert_raise ArgumentError, fn -> Serialize.serialize_string(stream, value, 16) end
      end
    end
  end

  describe "U12: end on a write or measure stream" do
    test "is a no-op that succeeds" do
      for stream <- writers() do
        assert {:ok, ^stream} = Serialize.serialize_end(stream)
      end
    end
  end

  describe "U14: the refusal name and a public fail" do
    test "refusal_name spells the family names, and none for no refusal" do
      assert Serialize.refusal_name(ReadStream.new(<<>>)) == "none"

      for reason <- ReadStream.refusals() do
        stream = ReadStream.fail(ReadStream.new(<<>>), reason)
        assert Serialize.refusal_name(stream) == Atom.to_string(reason)
      end
    end

    test "serialize_fail latches its reason, and anything outside the list as rejected" do
      assert {:error, stream} = Serialize.serialize_fail(ReadStream.new(<<0>>), :invalid_utf8)
      assert Serialize.refusal(stream) == :invalid_utf8
      assert {:error, stream} = Serialize.serialize_fail(stream, :past_end)
      assert Serialize.refusal(stream) == :invalid_utf8

      for reason <- [nil, :none, :bogus, 3] do
        assert {:error, stream} = Serialize.serialize_fail(ReadStream.new(<<0>>), runtime(reason))
        assert Serialize.refusal_name(stream) == "rejected"
      end
    end
  end

  describe "U15 and U16: compressed_float from precomputed constants" do
    @declarations [{0.0, 10.0, 0.01}, {-100.0, 100.0, 0.01}, {-1.0, 16_777_218.0, 1.0}]

    test "params derive what the declaration does, and the two entry points share the wire" do
      for {min, max, res} <- @declarations, value <- [min, (min + max) / 2, max, max * 2] do
        {:ok, {miv, bits, delta}} = Serialize.compressed_float_params(min, max, res)
        assert bits == Serialize.Bits.bits_required(0, miv)

        {:ok, a, _} =
          Serialize.serialize_compressed_float(WriteStream.new(), value, min, max, res)

        {:ok, b, _} =
          Serialize.serialize_compressed_float_precomputed(
            WriteStream.new(),
            value,
            miv,
            bits,
            delta,
            min
          )

        bytes = WriteStream.data(WriteStream.flush(a))
        assert bytes == WriteStream.data(WriteStream.flush(b))

        assert Serialize.serialize_compressed_float(ReadStream.new(bytes), nil, min, max, res) ==
                 Serialize.serialize_compressed_float_precomputed(
                   ReadStream.new(bytes),
                   nil,
                   miv,
                   bits,
                   delta,
                   min
                 )
      end
    end

    test "constants that are not what the params derive refuse on read" do
      for {miv, bits, delta} <- [
            {1000, 11, 10.0},
            {1000, 10, -10.0},
            {1000, 10, 0.0},
            {0, 1, 10.0},
            {4_294_967_295, 32, 10.0},
            {1000, 10, :x}
          ] do
        assert_declaration_refused(
          Serialize.serialize_compressed_float_precomputed(
            reader(),
            nil,
            runtime(miv),
            runtime(bits),
            runtime(delta),
            0.0
          )
        )
      end

      assert {:ok, _, _} =
               Serialize.serialize_compressed_float_precomputed(
                 reader(),
                 nil,
                 1000,
                 10,
                 10.0,
                 0.0
               )
    end

    test "inconsistent constants raise on write and measure" do
      for stream <- writers() do
        assert_raise ArgumentError, fn ->
          Serialize.serialize_compressed_float_precomputed(
            stream,
            1.0,
            1000,
            runtime(11),
            10.0,
            0.0
          )
        end
      end
    end
  end

  test "U8: a value that does not fit its width raises on write, the 64-bit path included" do
    for stream <- writers() do
      assert_raise ArgumentError, fn ->
        Serialize.serialize_bits(stream, runtime(1 <<< 45), 40)
      end
    end
  end
end
