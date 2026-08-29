defmodule Serialize.BitWriter do
  @moduledoc """
  Bitpacks unsigned integer values into a binary.

  The scratch-word packing model of STANDARD.md governs: values pack into a
  64-bit scratch least-significant-bit first, and each filled word is
  appended to the output as 8 little-endian bytes. BEAM integers are
  arbitrary precision, so the reference's spilled-bits recovery is a plain
  right shift by 64, and the scratch is masked to the 64-bit domain only
  when a word is emitted.

  The output binary is grown by appending, which the runtime optimizes into
  an amortized in-place extension for this single-writer pattern; there is
  no fixed buffer and no capacity, so writes never overflow. `data/1`
  returns the meaningful bytes — call `flush/1` first, exactly as the
  reference requires.
  """

  import Bitwise

  alias Serialize.Bits

  defstruct data: <<>>, scratch: 0, scratch_bits: 0, bits_written: 0

  @type t :: %__MODULE__{
          data: binary,
          scratch: non_neg_integer,
          scratch_bits: 0..63,
          bits_written: non_neg_integer
        }

  @word_mask 0xFFFFFFFFFFFFFFFF

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
    scratch = writer.scratch ||| (value &&& Bits.mask(bits)) <<< writer.scratch_bits
    scratch_bits = writer.scratch_bits + bits

    if scratch_bits >= 64 do
      word = scratch &&& @word_mask

      %{
        writer
        | data: <<writer.data::binary, word::little-64>>,
          scratch: scratch >>> 64,
          scratch_bits: scratch_bits - 64,
          bits_written: writer.bits_written + bits
      }
    else
      %{
        writer
        | scratch: scratch,
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

    # At byte alignment the scratch holds whole bytes of the current word;
    # its little-endian bytes followed by the payload are the wire bytes
    # from the current word boundary. Emit the completed words and retain
    # the partial tail as the new scratch, so later writes pack into it
    # exactly as if its bytes had gone through the packer.
    combined = <<writer.scratch::little-size(writer.scratch_bits), bytes::binary>>
    whole_words_bytes = byte_size(combined) - rem(byte_size(combined), 8)
    <<words::binary-size(^whole_words_bytes), tail::binary>> = combined

    scratch =
      case tail do
        <<>> -> 0
        _ -> :binary.decode_unsigned(tail, :little)
      end

    %{
      writer
      | data: <<writer.data::binary, words::binary>>,
        scratch: scratch,
        scratch_bits: byte_size(tail) * 8,
        bits_written: writer.bits_written + byte_size(bytes) * 8
    }
  end

  @doc """
  Flushes any partially filled scratch word to the output. The stream then
  occupies a whole number of 8-byte words, with zeros beyond the bit index.
  """
  @spec flush(t) :: t
  def flush(%__MODULE__{scratch_bits: 0} = writer), do: writer

  def flush(%__MODULE__{} = writer) do
    word = writer.scratch &&& @word_mask
    %{writer | data: <<writer.data::binary, word::little-64>>, scratch: 0, scratch_bits: 0}
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
