defmodule Serialize.BitWriter do
  @moduledoc """
  Bitpacks unsigned integer values into a binary.

  The scratch-word packing model of STANDARD.md governs: values pack into a
  scratch least-significant-bit first, and each filled word is appended to
  the output little-endian. The reference's word is 64 bits; this writer
  emits 32-bit words — the byte stream is identical, because little-endian
  words concatenate to the same little-endian bit stream at any word size —
  and splits each value at the word boundary before shifting, so every
  intermediate stays inside the BEAM's small-integer range (no value here
  ever reaches 2^32, well under the 60-bit boxing boundary).

  The output binary is grown by appending, which the runtime optimizes into
  an amortized in-place extension for this single-writer pattern; there is
  no fixed buffer and no capacity, so writes never overflow. `data/1`
  returns the meaningful bytes — call `flush/1` first, exactly as the
  reference requires.
  """

  import Bitwise

  defstruct data: <<>>, scratch: 0, scratch_bits: 0, bits_written: 0

  @type t :: %__MODULE__{
          data: binary,
          scratch: non_neg_integer,
          scratch_bits: 0..31,
          bits_written: non_neg_integer
        }

  @doc "A fresh writer with an empty stream."
  @spec new() :: t
  def new, do: %__MODULE__{}

  @doc """
  Writes the low `bits` bits of `value`, where `bits` is in `[1, 32]`.

  The value is masked to the field width, so bits above the width can never
  corrupt neighboring fields; a caller passing an over-wide value is
  violating the trusted-writes contract either way.
  """
  @spec write_bits(t, non_neg_integer, 1..32) :: t
  def write_bits(%__MODULE__{} = writer, value, bits)
      when is_integer(value) and value >= 0 and is_integer(bits) and bits >= 1 and bits <= 32 do
    value = value &&& (1 <<< bits) - 1
    scratch_bits = writer.scratch_bits + bits

    if scratch_bits >= 32 do
      # split at the word boundary before shifting: the low part completes
      # the 32-bit word, the high part becomes the new scratch, and neither
      # side of either shift can reach 2^32
      low_take = 32 - writer.scratch_bits
      word = writer.scratch ||| (value &&& (1 <<< low_take) - 1) <<< writer.scratch_bits

      %{
        writer
        | data: <<writer.data::binary, word::little-32>>,
          scratch: value >>> low_take,
          scratch_bits: scratch_bits - 32,
          bits_written: writer.bits_written + bits
      }
    else
      %{
        writer
        | scratch: writer.scratch ||| value <<< writer.scratch_bits,
          scratch_bits: scratch_bits,
          bits_written: writer.bits_written + bits
      }
    end
  end

  @doc """
  Pads with zero bits until the bit index is a multiple of 8. If the stream
  is already aligned, nothing is written.
  """
  @spec write_align(t) :: t
  def write_align(%__MODULE__{} = writer) do
    case rem(writer.bits_written, 8) do
      0 -> writer
      remainder -> write_bits(writer, 0, 8 - remainder)
    end
  end

  @doc """
  Writes raw bytes. The stream must be byte aligned — the callers align
  first, exactly as the reference's `SerializeBytes` does.
  """
  @spec write_bytes(t, binary) :: t
  def write_bytes(%__MODULE__{} = writer, bytes) when is_binary(bytes) do
    0 = rem(writer.bits_written, 8)

    {data, scratch, scratch_bits} =
      pack_bytes(writer.data, writer.scratch, writer.scratch_bits, bytes)

    %{
      writer
      | data: data,
        scratch: scratch,
        scratch_bits: scratch_bits,
        bits_written: writer.bits_written + byte_size(bytes) * 8
    }
  end

  @doc """
  The raw-bytes append on plain packer state, for a byte-aligned stream —
  shared with the streams that carry the packer state inline
  (`Serialize.WriteStream`).

  At byte alignment the scratch holds whole bytes of the current word; its
  little-endian bytes followed by the payload are the wire bytes from the
  current word boundary. The completed words are emitted and the partial
  tail retained as the new scratch, so later writes pack into it exactly as
  if its bytes had gone through the packer.
  """
  @spec pack_bytes(binary, non_neg_integer, 0..31, binary) :: {binary, non_neg_integer, 0..31}
  def pack_bytes(data, scratch, scratch_bits, bytes) do
    combined = <<scratch::little-size(scratch_bits), bytes::binary>>
    whole_words_bytes = byte_size(combined) - rem(byte_size(combined), 4)
    <<words::binary-size(^whole_words_bytes), tail::binary>> = combined

    scratch =
      case tail do
        <<>> -> 0
        _ -> :binary.decode_unsigned(tail, :little)
      end

    {<<data::binary, words::binary>>, scratch, byte_size(tail) * 8}
  end

  @doc """
  Flushes any partially filled scratch word to the output. The stream then
  occupies a whole number of words, with zeros beyond the bit index.
  """
  @spec flush(t) :: t
  def flush(%__MODULE__{scratch_bits: 0} = writer), do: writer

  def flush(%__MODULE__{} = writer) do
    %{
      writer
      | data: <<writer.data::binary, writer.scratch::little-32>>,
        scratch: 0,
        scratch_bits: 0
    }
  end

  @doc """
  The meaningful bytes written: the bit count rounded up to a byte.
  Call `flush/1` first.
  """
  @spec data(t) :: binary
  def data(%__MODULE__{} = writer) do
    binary_part(writer.data, 0, min(byte_size(writer.data), bytes_written(writer)))
  end

  @doc "The number of zero pad bits an align would write now, in `[0, 7]`."
  @spec align_bits(t) :: 0..7
  def align_bits(%__MODULE__{} = writer), do: rem(8 - rem(writer.bits_written, 8), 8)

  @doc "The number of bits written so far."
  @spec bits_written(t) :: non_neg_integer
  def bits_written(%__MODULE__{} = writer), do: writer.bits_written

  @doc "The number of bits written, rounded up to a byte."
  @spec bytes_written(t) :: non_neg_integer
  def bytes_written(%__MODULE__{} = writer), do: div(writer.bits_written + 7, 8)
end
