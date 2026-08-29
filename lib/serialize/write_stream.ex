defmodule Serialize.WriteStream do
  @moduledoc """
  Stream for writing bitpacked data: the write-mode counterpart of the
  reference's `WriteStream`.

  The packer state — the output binary, the scratch word and the bit
  count — lives directly in this struct, so each operation allocates
  exactly one updated stream. The packing arithmetic is the 32-bit-word
  model of `Serialize.BitWriter`, carried here inline for the hot bit path
  (the two implementations are held together by the shared golden battery);
  the raw-bytes append goes through `BitWriter.pack_bytes/4`, the model's
  single home for that step.

  Writes assume trusted data (STANDARD.md): caller contract violations
  raise `ArgumentError` — the misuse convention of this implementation —
  and every operation otherwise succeeds. Use the unified operations in
  `Serialize`; the methods here are the write-mode primitives they
  dispatch to.
  """

  import Bitwise

  alias Serialize.{Bits, BitWriter}

  defstruct data: <<>>, scratch: 0, scratch_bits: 0, bits_written: 0

  @type t :: %__MODULE__{
          data: binary,
          scratch: non_neg_integer,
          scratch_bits: 0..31,
          bits_written: non_neg_integer
        }

  @doc "A fresh write stream with an empty output."
  @spec new() :: t
  def new, do: %__MODULE__{}

  # The scratch-word packing step, on this struct: BitWriter.write_bits's
  # arithmetic — split at the 32-bit word boundary before shifting, so
  # every intermediate stays a small integer — producing the one allocation
  # the operation costs.
  defp write_bits_flat(stream, value, bits) do
    scratch_bits = stream.scratch_bits + bits

    if scratch_bits >= 32 do
      low_take = 32 - stream.scratch_bits
      word = stream.scratch ||| (value &&& (1 <<< low_take) - 1) <<< stream.scratch_bits

      %{
        stream
        | data: <<stream.data::binary, word::little-32>>,
          scratch: value >>> low_take,
          scratch_bits: scratch_bits - 32,
          bits_written: stream.bits_written + bits
      }
    else
      %{
        stream
        | scratch: stream.scratch ||| value <<< stream.scratch_bits,
          scratch_bits: scratch_bits,
          bits_written: stream.bits_written + bits
      }
    end
  end

  @doc "Writes a ranged 32-bit integer as its offset from `min`."
  @spec serialize_integer(t, integer, integer, integer) :: {:ok, t, integer}
  def serialize_integer(%__MODULE__{} = stream, value, min, max) do
    unless is_integer(value) and value >= min and value <= max do
      raise ArgumentError, "serialize_int value #{inspect(value)} outside [#{min}, #{max}]"
    end

    case Bits.bits_required(min, max) do
      0 -> {:ok, stream, value}
      bits -> {:ok, write_bits_flat(stream, value - min, bits), value}
    end
  end

  @doc """
  Writes a ranged 64-bit integer as its offset from `min`: a single group
  for 32 bits or fewer, otherwise the low 32 bits first and the high
  remainder second.
  """
  @spec serialize_integer64(t, integer, integer, integer) :: {:ok, t, integer}
  def serialize_integer64(%__MODULE__{} = stream, value, min, max) do
    unless is_integer(value) and value >= min and value <= max do
      raise ArgumentError, "serialize_int64 value #{inspect(value)} outside [#{min}, #{max}]"
    end

    case Bits.bits_required(min, max) do
      0 ->
        {:ok, stream, value}

      bits ->
        offset = value - min

        stream =
          if bits <= 32 do
            write_bits_flat(stream, offset, bits)
          else
            stream
            |> write_bits_flat(offset &&& 0xFFFFFFFF, 32)
            |> write_bits_flat(offset >>> 32, bits - 32)
          end

        {:ok, stream, value}
    end
  end

  @doc """
  Writes a ranged 128-bit integer as its offset from `min`, in 32-bit
  groups from least significant upward, the final group carrying the
  remainder.
  """
  @spec serialize_integer128(t, integer, integer, integer) :: {:ok, t, integer}
  def serialize_integer128(%__MODULE__{} = stream, value, min, max) do
    unless is_integer(value) and value >= min and value <= max do
      raise ArgumentError, "serialize_int128 value #{inspect(value)} outside [#{min}, #{max}]"
    end

    bits = Bits.bits_required(min, max)
    {:ok, write_groups(stream, value - min, bits), value}
  end

  defp write_groups(stream, offset, bits) when bits <= 32 do
    write_bits_flat(stream, offset &&& (1 <<< bits) - 1, bits)
  end

  defp write_groups(stream, offset, bits) do
    stream
    |> write_bits_flat(offset &&& 0xFFFFFFFF, 32)
    |> write_groups(offset >>> 32, bits - 32)
  end

  @doc "Writes the low `bits` bits of `value`, `bits` in `[1, 32]`."
  @spec serialize_bits(t, non_neg_integer, 1..32) :: {:ok, t, non_neg_integer}
  def serialize_bits(%__MODULE__{} = stream, value, bits) do
    unless is_integer(value) and value >= 0 and value <= (1 <<< bits) - 1 do
      raise ArgumentError, "serialize_bits value #{inspect(value)} does not fit #{bits} bits"
    end

    {:ok, write_bits_flat(stream, value, bits), value}
  end

  @doc "Aligns, then writes `count` raw bytes."
  @spec serialize_bytes(t, binary, non_neg_integer) :: {:ok, t, binary}
  def serialize_bytes(%__MODULE__{} = stream, data, count) do
    unless is_binary(data) and byte_size(data) == count do
      raise ArgumentError, "serialize_bytes data does not match count #{count}"
    end

    {:ok, stream} = serialize_align(stream)

    {out, scratch, scratch_bits} =
      BitWriter.pack_bytes(stream.data, stream.scratch, stream.scratch_bits, data)

    stream = %{
      stream
      | data: out,
        scratch: scratch,
        scratch_bits: scratch_bits,
        bits_written: stream.bits_written + byte_size(data) * 8
    }

    {:ok, stream, data}
  end

  @doc "Pads with zero bits to the next byte boundary."
  @spec serialize_align(t) :: {:ok, t}
  def serialize_align(%__MODULE__{} = stream) do
    case rem(stream.bits_written, 8) do
      0 -> {:ok, stream}
      remainder -> {:ok, write_bits_flat(stream, 0, 8 - remainder)}
    end
  end

  @doc "The number of zero pad bits an align would write now, in `[0, 7]`."
  @spec align_bits(t) :: 0..7
  def align_bits(%__MODULE__{} = stream), do: rem(8 - rem(stream.bits_written, 8), 8)

  @doc "Flushes the final partial word. Call before `data/1`."
  @spec flush(t) :: t
  def flush(%__MODULE__{scratch_bits: 0} = stream), do: stream

  def flush(%__MODULE__{} = stream) do
    %{
      stream
      | data: <<stream.data::binary, stream.scratch::little-32>>,
        scratch: 0,
        scratch_bits: 0
    }
  end

  @doc "The bytes written. Call `flush/1` first."
  @spec data(t) :: binary
  def data(%__MODULE__{} = stream) do
    binary_part(stream.data, 0, min(byte_size(stream.data), bytes_processed(stream)))
  end

  @doc "The number of bits written so far."
  @spec bits_processed(t) :: non_neg_integer
  def bits_processed(%__MODULE__{} = stream), do: stream.bits_written

  @doc "The number of bytes written so far: the bit count rounded up."
  @spec bytes_processed(t) :: non_neg_integer
  def bytes_processed(%__MODULE__{} = stream), do: div(stream.bits_written + 7, 8)
end
