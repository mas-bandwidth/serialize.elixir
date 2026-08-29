defmodule Serialize.MeasureTest do
  use ExUnit.Case, async: true

  alias Serialize.{MeasureStream, WriteStream}

  test "the ruling's worked example: { bits(8); align; bits(8) } measures 23 bits" do
    measure = MeasureStream.new()
    {:ok, measure, _} = Serialize.serialize_bits(measure, 0xAB, 8)
    {:ok, measure} = Serialize.serialize_align(measure)
    {:ok, measure, _} = Serialize.serialize_bits(measure, 0xAB, 8)

    # 8 + 7 + 8: the conservative charge. an exact-from-zero measure
    # reports 16 — 2 bytes — which is NOT enough room at bit offset 1.
    assert Serialize.bits_processed(measure) == 23

    # written at every starting offset, the actual span never exceeds it
    for offset <- 0..7 do
      writer = WriteStream.new()

      writer =
        if offset > 0 do
          {:ok, writer, _} = Serialize.serialize_bits(writer, 0, offset)
          writer
        else
          writer
        end

      start = Serialize.bits_processed(writer)
      {:ok, writer, _} = Serialize.serialize_bits(writer, 0xAB, 8)
      {:ok, writer} = Serialize.serialize_align(writer)
      {:ok, writer, _} = Serialize.serialize_bits(writer, 0xAB, 8)
      span = Serialize.bits_processed(writer) - start

      assert span <= 23
      if offset == 0, do: assert(span == 16)
      if offset == 1, do: assert(span == 23)
    end
  end

  test "align charges 7 even when the measure is byte-aligned" do
    measure = MeasureStream.new()
    {:ok, measure, _} = Serialize.serialize_bits(measure, 0, 8)
    assert Serialize.align_bits(measure) == 7
    {:ok, measure} = Serialize.serialize_align(measure)
    assert Serialize.bits_processed(measure) == 15
  end

  test "a measure never refuses and processes every operation of the surface" do
    measure = MeasureStream.new()
    {:ok, measure, _} = Serialize.serialize_int(measure, 0, -100, 100)
    {:ok, measure, _} = Serialize.serialize_bool(measure, true)
    {:ok, measure, _} = Serialize.serialize_float(measure, 1.0)
    {:ok, measure, _} = Serialize.serialize_double(measure, 1.0)
    {:ok, measure, _} = Serialize.serialize_string(measure, "abc", 8)
    {:ok, measure, _} = Serialize.serialize_wstring(measure, "abc", 8)
    {:ok, measure, _} = Serialize.serialize_bytes(measure, <<1>>, 1)
    {:ok, measure, _} = Serialize.serialize_int_relative(measure, 1, 2)
    {:ok, measure, _} = Serialize.serialize_fixed(measure, 0, 16, 16, -1, 1)
    assert Serialize.bits_processed(measure) > 0
    assert Serialize.bytes_processed(measure) == div(Serialize.bits_processed(measure) + 7, 8)
  end
end
