defmodule Serialize.ReadStream do
  @moduledoc """
  Stream for reading bitpacked data: the read-mode counterpart of the
  reference's `ReadStream`.

  The reader state — the data, its bit length and the bit position — lives
  directly in this struct, so each operation allocates exactly one updated
  stream; the window decode itself is `Serialize.BitReader.decode_bits/3`,
  the packing model's single home.

  Reads validate always: the bytes come from the network, so every refusal
  rule of STANDARD.md binds here — out-of-range offsets, non-zero align
  padding and truncated data refuse as `{:error, stream}` values, and
  hostile bytes never raise. A refusal is terminal for the stream: nothing
  after the failing operation has a defined position.
  """

  import Bitwise

  alias Serialize.{BitReader, Bits}

  defstruct data: <<>>, num_bits: 0, bits_read: 0

  @type t :: %__MODULE__{
          data: binary,
          num_bits: non_neg_integer,
          bits_read: non_neg_integer
        }

  @doc "A read stream over the given bytes."
  @spec new(binary) :: t
  def new(data) when is_binary(data) do
    %__MODULE__{data: data, num_bits: byte_size(data) * 8}
  end

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
    if stream.bits_read + bits > stream.num_bits do
      {:error, stream}
    else
      {offset, bits_read} = read_groups(stream.data, stream.bits_read, bits, 0, 0)

      if offset > max - min do
        {:error, %{stream | bits_read: bits_read}}
      else
        {:ok, %{stream | bits_read: bits_read}, min + offset}
      end
    end
  end

  # 32-bit groups from least significant upward on plain values: the value
  # accumulated so far, and the advanced bit position.
  defp read_groups(data, bits_read, bits, acc, shift) when bits <= 32 do
    group = BitReader.decode_bits(data, bits_read, bits)
    {acc ||| group <<< shift, bits_read + bits}
  end

  defp read_groups(data, bits_read, bits, acc, shift) do
    group = BitReader.decode_bits(data, bits_read, 32)
    read_groups(data, bits_read + 32, bits - 32, acc ||| group <<< shift, shift + 32)
  end

  @doc "Reads `bits` bits, `bits` in `[1, 32]`."
  @spec serialize_bits(t, term, 1..32) :: {:ok, t, non_neg_integer} | {:error, t}
  def serialize_bits(%__MODULE__{} = stream, _value, bits) do
    if stream.bits_read + bits > stream.num_bits do
      {:error, stream}
    else
      value = BitReader.decode_bits(stream.data, stream.bits_read, bits)
      {:ok, %{stream | bits_read: stream.bits_read + bits}, value}
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
          if count > div(stream.num_bits - stream.bits_read, 8) do
            {:error, stream}
          else
            bytes = binary_part(stream.data, stream.bits_read >>> 3, count)
            {:ok, %{stream | bits_read: stream.bits_read + count * 8}, bytes}
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
    case rem(stream.bits_read, 8) do
      0 ->
        {:ok, stream}

      remainder ->
        bits = 8 - remainder

        cond do
          stream.bits_read + bits > stream.num_bits ->
            {:error, stream}

          BitReader.decode_bits(stream.data, stream.bits_read, bits) != 0 ->
            # the padding bits are consumed either way, as in the reference
            {:error, %{stream | bits_read: stream.bits_read + bits}}

          true ->
            {:ok, %{stream | bits_read: stream.bits_read + bits}}
        end
    end
  end

  @doc "The number of zero pad bits an align would read now, in `[0, 7]`."
  @spec align_bits(t) :: 0..7
  def align_bits(%__MODULE__{} = stream), do: rem(8 - rem(stream.bits_read, 8), 8)

  @doc "The number of bits read so far."
  @spec bits_processed(t) :: non_neg_integer
  def bits_processed(%__MODULE__{} = stream), do: stream.bits_read

  @doc "The number of bytes read so far: the bit count rounded up."
  @spec bytes_processed(t) :: non_neg_integer
  def bytes_processed(%__MODULE__{} = stream), do: div(stream.bits_read + 7, 8)
end
