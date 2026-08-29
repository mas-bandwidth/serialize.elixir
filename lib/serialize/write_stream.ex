defmodule Serialize.WriteStream do
  @moduledoc """
  Stream for writing bitpacked data: the write-mode counterpart of the
  reference's `WriteStream`, wrapping `Serialize.BitWriter`.

  Writes assume trusted data (STANDARD.md): caller contract violations
  raise `ArgumentError` — the misuse convention of this implementation —
  and every operation otherwise succeeds. Use the unified operations in
  `Serialize`; the methods here are the write-mode primitives they
  dispatch to.
  """

  import Bitwise

  alias Serialize.{Bits, BitWriter}

  defstruct writer: nil

  @type t :: %__MODULE__{writer: BitWriter.t()}

  @doc "A fresh write stream with an empty output."
  @spec new() :: t
  def new, do: %__MODULE__{writer: BitWriter.new()}

  @doc "Writes a ranged 32-bit integer as its offset from `min`."
  @spec serialize_integer(t, integer, integer, integer) :: {:ok, t, integer}
  def serialize_integer(%__MODULE__{} = stream, value, min, max) do
    unless is_integer(value) and value >= min and value <= max do
      raise ArgumentError, "serialize_int value #{value} outside [#{min}, #{max}]"
    end

    case Bits.bits_required(min, max) do
      0 ->
        {:ok, stream, value}

      bits ->
        {:ok, %{stream | writer: BitWriter.write_bits(stream.writer, value - min, bits)}, value}
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
      raise ArgumentError, "serialize_int64 value #{value} outside [#{min}, #{max}]"
    end

    case Bits.bits_required(min, max) do
      0 ->
        {:ok, stream, value}

      bits ->
        offset = value - min

        writer =
          if bits <= 32 do
            BitWriter.write_bits(stream.writer, offset, bits)
          else
            stream.writer
            |> BitWriter.write_bits(offset &&& 0xFFFFFFFF, 32)
            |> BitWriter.write_bits(offset >>> 32, bits - 32)
          end

        {:ok, %{stream | writer: writer}, value}
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
      raise ArgumentError, "serialize_int128 value #{value} outside [#{min}, #{max}]"
    end

    bits = Bits.bits_required(min, max)
    {:ok, %{stream | writer: write_groups(stream.writer, value - min, bits)}, value}
  end

  @doc false
  @spec write_groups(BitWriter.t(), non_neg_integer, pos_integer) :: BitWriter.t()
  def write_groups(writer, offset, bits) when bits <= 32 do
    BitWriter.write_bits(writer, offset, bits)
  end

  def write_groups(writer, offset, bits) do
    writer
    |> BitWriter.write_bits(offset &&& 0xFFFFFFFF, 32)
    |> write_groups(offset >>> 32, bits - 32)
  end

  @doc "Writes the low `bits` bits of `value`, `bits` in `[1, 32]`."
  @spec serialize_bits(t, non_neg_integer, 1..32) :: {:ok, t, non_neg_integer}
  def serialize_bits(%__MODULE__{} = stream, value, bits) do
    unless is_integer(value) and value >= 0 and value <= Bits.mask(bits) do
      raise ArgumentError, "serialize_bits value #{value} does not fit #{bits} bits"
    end

    {:ok, %{stream | writer: BitWriter.write_bits(stream.writer, value, bits)}, value}
  end

  @doc "Aligns, then writes `count` raw bytes."
  @spec serialize_bytes(t, binary, non_neg_integer) :: {:ok, t, binary}
  def serialize_bytes(%__MODULE__{} = stream, data, count) do
    unless is_binary(data) and byte_size(data) == count do
      raise ArgumentError, "serialize_bytes data does not match count #{count}"
    end

    writer = stream.writer |> BitWriter.write_align() |> BitWriter.write_bytes(data)
    {:ok, %{stream | writer: writer}, data}
  end

  @doc "Pads with zero bits to the next byte boundary."
  @spec serialize_align(t) :: {:ok, t}
  def serialize_align(%__MODULE__{} = stream) do
    {:ok, %{stream | writer: BitWriter.write_align(stream.writer)}}
  end

  @doc "The number of zero pad bits an align would write now, in `[0, 7]`."
  @spec align_bits(t) :: 0..7
  def align_bits(%__MODULE__{} = stream), do: BitWriter.align_bits(stream.writer)

  @doc "Flushes the final partial word. Call before `data/1`."
  @spec flush(t) :: t
  def flush(%__MODULE__{} = stream), do: %{stream | writer: BitWriter.flush(stream.writer)}

  @doc "The bytes written. Call `flush/1` first."
  @spec data(t) :: binary
  def data(%__MODULE__{} = stream), do: BitWriter.data(stream.writer)

  @doc "The number of bits written so far."
  @spec bits_processed(t) :: non_neg_integer
  def bits_processed(%__MODULE__{} = stream), do: BitWriter.bits_written(stream.writer)

  @doc "The number of bytes written so far: the bit count rounded up."
  @spec bytes_processed(t) :: non_neg_integer
  def bytes_processed(%__MODULE__{} = stream), do: BitWriter.bytes_written(stream.writer)
end
