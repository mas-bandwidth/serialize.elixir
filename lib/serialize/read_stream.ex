defmodule Serialize.ReadStream do
  @moduledoc """
  Stream for reading bitpacked data: the read-mode counterpart of the
  reference's `ReadStream`, wrapping `Serialize.BitReader`.

  Reads validate always: the bytes come from the network, so every refusal
  rule of STANDARD.md binds here — out-of-range offsets, non-zero align
  padding and truncated data refuse as `{:error, stream}` values, and
  hostile bytes never raise. A refusal is terminal for the stream: nothing
  after the failing operation has a defined position.
  """

  import Bitwise

  alias Serialize.{Bits, BitReader}

  defstruct reader: nil

  @type t :: %__MODULE__{reader: BitReader.t()}

  @doc "A read stream over the given bytes."
  @spec new(binary) :: t
  def new(data) when is_binary(data), do: %__MODULE__{reader: BitReader.new(data)}

  @doc """
  Reads a ranged 32-bit integer. The decoded offset must lie within the
  range — reject, never clamp.
  """
  @spec serialize_integer(t, term, integer, integer) :: {:ok, t, integer} | {:error, t}
  def serialize_integer(%__MODULE__{} = stream, _value, min, max) do
    read_ranged(stream, min, max, Bits.bits_required(min, max))
  end

  @doc "Reads a ranged 64-bit integer: low group first, then the remainder."
  @spec serialize_integer64(t, term, integer, integer) :: {:ok, t, integer} | {:error, t}
  def serialize_integer64(%__MODULE__{} = stream, _value, min, max) do
    read_ranged(stream, min, max, Bits.bits_required(min, max))
  end

  @doc """
  Reads a ranged 128-bit integer: 32-bit groups from least significant
  upward, the final group carrying the remainder.
  """
  @spec serialize_integer128(t, term, integer, integer) :: {:ok, t, integer} | {:error, t}
  def serialize_integer128(%__MODULE__{} = stream, _value, min, max) do
    read_ranged(stream, min, max, Bits.bits_required(min, max))
  end

  # The shared ranged read: one up-front bounds check against the total
  # width (the reference's SerializeInteger/64/128 shape — a refused read
  # consumes nothing), then the offset in 32-bit groups from the bottom.
  defp read_ranged(stream, min, _max, 0), do: {:ok, stream, min}

  defp read_ranged(stream, min, max, bits) do
    if BitReader.would_read_past_end?(stream.reader, bits) do
      {:error, stream}
    else
      {offset, reader} = read_groups(stream.reader, bits, 0, 0)

      if offset > max - min do
        {:error, %{stream | reader: reader}}
      else
        {:ok, %{stream | reader: reader}, min + offset}
      end
    end
  end

  @doc false
  @spec read_groups(BitReader.t(), pos_integer, non_neg_integer, non_neg_integer) ::
          {non_neg_integer, BitReader.t()}
  def read_groups(reader, bits, acc, shift) when bits <= 32 do
    {group, reader} = BitReader.read_bits(reader, bits)
    {acc ||| group <<< shift, reader}
  end

  def read_groups(reader, bits, acc, shift) do
    {group, reader} = BitReader.read_bits(reader, 32)
    read_groups(reader, bits - 32, acc ||| group <<< shift, shift + 32)
  end

  @doc "Reads `bits` bits, `bits` in `[1, 32]`."
  @spec serialize_bits(t, term, 1..32) :: {:ok, t, non_neg_integer} | {:error, t}
  def serialize_bits(%__MODULE__{} = stream, _value, bits) do
    if BitReader.would_read_past_end?(stream.reader, bits) do
      {:error, stream}
    else
      {value, reader} = BitReader.read_bits(stream.reader, bits)
      {:ok, %{stream | reader: reader}, value}
    end
  end

  @doc """
  Aligns — verifying the padding bits are zero — then reads `count` raw
  bytes, compared against the remaining whole bytes.
  """
  @spec serialize_bytes(t, term, integer) :: {:ok, t, binary} | {:error, t}
  def serialize_bytes(%__MODULE__{} = stream, _data, count) do
    if count < 0 do
      {:error, stream}
    else
      case serialize_align(stream) do
        {:error, stream} ->
          {:error, stream}

        {:ok, stream} ->
          # compared in bytes rather than bits, consistent with the
          # reference's 64-bit bookkeeping
          if count > div(BitReader.bits_remaining(stream.reader), 8) do
            {:error, stream}
          else
            {bytes, reader} = BitReader.read_bytes(stream.reader, count)
            {:ok, %{stream | reader: reader}, bytes}
          end
      end
    end
  end

  @doc """
  Reads an align: the padding bits to the next byte boundary must be
  present and zero.
  """
  @spec serialize_align(t) :: {:ok, t} | {:error, t}
  def serialize_align(%__MODULE__{} = stream) do
    if BitReader.would_read_past_end?(stream.reader, BitReader.align_bits(stream.reader)) do
      {:error, stream}
    else
      case BitReader.read_align(stream.reader) do
        {:ok, reader} -> {:ok, %{stream | reader: reader}}
        {:error, reader} -> {:error, %{stream | reader: reader}}
      end
    end
  end

  @doc "The number of zero pad bits an align would read now, in `[0, 7]`."
  @spec align_bits(t) :: 0..7
  def align_bits(%__MODULE__{} = stream), do: BitReader.align_bits(stream.reader)

  @doc "The number of bits read so far."
  @spec bits_processed(t) :: non_neg_integer
  def bits_processed(%__MODULE__{} = stream), do: BitReader.bits_read(stream.reader)

  @doc "The number of bytes read so far: the bit count rounded up."
  @spec bytes_processed(t) :: non_neg_integer
  def bytes_processed(%__MODULE__{} = stream) do
    div(BitReader.bits_read(stream.reader) + 7, 8)
  end
end
