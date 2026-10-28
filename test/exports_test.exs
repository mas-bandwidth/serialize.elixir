defmodule Serialize.ExportsTest do
  @moduledoc """
  IMPLEMENTING.md U15, "Exports beyond the reference operations": the
  documented surface is the reference operations, the three streams and
  their accessors, the refusal list and its name function, copy_string,
  the reference's public helpers (`bits_required`, `compressed_float_params`,
  `BitWriter`, `BitReader`), and the language necessities (`Float32`).
  Elixir cannot hide a function another module calls, so every other
  public function is `@doc false`, documented as internal, with no promise.
  This pins the documented set exactly.
  """

  use ExUnit.Case, async: true

  @surface %{
    Serialize => ~w(
      serialize_bits serialize_uint8 serialize_uint16 serialize_uint32 serialize_uint64
      serialize_uint128 serialize_bool serialize_int serialize_int64 serialize_int128
      serialize_float serialize_double serialize_compressed_float compressed_float_params
      serialize_compressed_float_precomputed serialize_int_relative serialize_fixed
      serialize_align serialize_bytes serialize_string serialize_copy_string serialize_end
      serialize_reject serialize_object serialize_fail bits_processed bytes_processed
      refusal refusal_name align_bits
    ),
    Serialize.WriteStream => ~w(new flush data bits_processed bytes_processed align_bits),
    Serialize.ReadStream =>
      ~w(new refusals fail failed? refusal bits_processed bytes_processed align_bits),
    Serialize.MeasureStream => ~w(new bits_processed bytes_processed align_bits),
    Serialize.Bits => ~w(bits_required),
    Serialize.BitWriter =>
      ~w(new write_bits write_align write_bytes flush data align_bits bits_written bytes_written),
    Serialize.BitReader =>
      ~w(new would_read_past_end? read_bits read_align read_bytes align_bits bits_read bits_remaining),
    Serialize.Float32 => ~w(bits32 value32 bits64 value64 finite32? finite64? round32 round32!)
  }

  defp documented(module) do
    {:docs_v1, _, _, _, _, _, docs} = Code.fetch_docs(module)

    for {{:function, name, _arity}, _, _, doc, _} <- docs, doc != :hidden, uniq: true do
      Atom.to_string(name)
    end
  end

  test "each module documents exactly the U15 surface" do
    for {module, names} <- @surface do
      assert Enum.sort(documented(module)) == Enum.sort(names), inspect(module)
    end
  end

  test "the hidden names are still callable: internal, not removed" do
    for {module, name, arity} <- [
          {Serialize.WriteStream, :serialize_bits, 3},
          {Serialize.ReadStream, :reject, 1},
          {Serialize.Bits, :mask, 1},
          {Serialize.BitWriter, :pack_bytes, 4},
          {Serialize.BitReader, :decode_bits, 3}
        ] do
      assert function_exported?(Code.ensure_loaded!(module), name, arity)
    end
  end
end
