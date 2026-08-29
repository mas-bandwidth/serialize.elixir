defmodule Serialize.BitReader do
  @moduledoc """
  Reads bitpacked unsigned integer values from a binary.

  Each read decodes a little-endian window at the current byte position and
  shifts by the bit remainder — the reference's branchless window model,
  with the window priced inside the binary: bytes past the end of the data
  are never loaded and never interpreted, so callers owe no allocation
  slack beyond the data itself (STANDARD.md "Past-end memory is an
  implementation contract"). The window is 40 bits — enough for a 7-bit
  offset plus a 32-bit field, and small enough that the decoded value never
  leaves the BEAM's small-integer range. Reads share the underlying binary;
  nothing is copied.

  The reader trusts its callers to check `would_read_past_end?/2` before
  reading, exactly as the reference's streams do.
  """

  import Bitwise

  defstruct data: <<>>, num_bits: 0, bits_read: 0

  @type t :: %__MODULE__{
          data: binary,
          num_bits: non_neg_integer,
          bits_read: non_neg_integer
        }

  @doc "A reader over the given bytes."
  @spec new(binary) :: t
  def new(data) when is_binary(data) do
    %__MODULE__{data: data, num_bits: byte_size(data) * 8}
  end

  @doc "Whether reading `bits` more bits would pass the end of the data."
  @spec would_read_past_end?(t, non_neg_integer) :: boolean
  def would_read_past_end?(%__MODULE__{} = reader, bits) do
    reader.bits_read + bits > reader.num_bits
  end

  @doc """
  Reads `bits` bits, where `bits` is in `[1, 32]`, returning the value and
  the advanced reader. The caller has already checked the bounds.
  """
  @spec read_bits(t, 1..32) :: {non_neg_integer, t}
  def read_bits(%__MODULE__{} = reader, bits)
      when is_integer(bits) and bits >= 1 and bits <= 32 do
    {decode_bits(reader.data, reader.bits_read, bits),
     %{reader | bits_read: reader.bits_read + bits}}
  end

  @doc """
  The window decode itself, on plain values: the `bits` bits of `data` at
  bit position `bits_read`. The packing model in one place — the streams
  that carry their position inline (`Serialize.ReadStream`) decode through
  this too. The caller has already checked the bounds.
  """
  @spec decode_bits(binary, non_neg_integer, 1..32) :: non_neg_integer
  def decode_bits(data, bits_read, bits) do
    byte_index = bits_read >>> 3
    bit_offset = bits_read &&& 7

    window =
      case data do
        <<_::binary-size(^byte_index), word::little-40, _::binary>> ->
          word

        <<_::binary-size(^byte_index), rest::binary>> ->
          :binary.decode_unsigned(rest, :little)
      end

    window >>> bit_offset &&& (1 <<< bits) - 1
  end

  @doc """
  Reads an align: skips ahead to the next byte boundary, verifying the
  padding bits are zero. Returns `{:error, reader}` when they are not —
  the padding bits are consumed either way, as in the reference.
  """
  @spec read_align(t) :: {:ok, t} | {:error, t}
  def read_align(%__MODULE__{} = reader) do
    case rem(reader.bits_read, 8) do
      0 ->
        {:ok, reader}

      remainder ->
        case read_bits(reader, 8 - remainder) do
          {0, reader} -> {:ok, reader}
          {_nonzero, reader} -> {:error, reader}
        end
    end
  end

  @doc """
  Reads `count` raw bytes at a byte-aligned position, returning a
  sub-binary of the data — no copy. The caller has aligned and checked the
  bounds.
  """
  @spec read_bytes(t, non_neg_integer) :: {binary, t}
  def read_bytes(%__MODULE__{} = reader, count)
      when is_integer(count) and count >= 0 do
    0 = rem(reader.bits_read, 8)
    bytes = binary_part(reader.data, reader.bits_read >>> 3, count)
    {bytes, %{reader | bits_read: reader.bits_read + count * 8}}
  end

  @doc "The number of zero pad bits an align would read now, in `[0, 7]`."
  @spec align_bits(t) :: 0..7
  def align_bits(%__MODULE__{} = reader), do: rem(8 - rem(reader.bits_read, 8), 8)

  @doc "The number of bits read so far."
  @spec bits_read(t) :: non_neg_integer
  def bits_read(%__MODULE__{} = reader), do: reader.bits_read

  @doc "The number of bits still available to read."
  @spec bits_remaining(t) :: non_neg_integer
  def bits_remaining(%__MODULE__{} = reader), do: reader.num_bits - reader.bits_read
end
