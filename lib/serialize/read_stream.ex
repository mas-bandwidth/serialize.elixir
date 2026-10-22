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
  hostile bytes never raise.

  Failure is terminal, in the standard's **latch** shape: this stream
  survives a refusal, so it carries a `failed` flag, the first refusal sets
  it, and every later read on that stream returns `{:error, stream}`
  immediately — consuming no bits and decoding nothing. The rule is
  uniform: any read that returns `{:error, stream}` latches it. A failure
  persists until the stream is re-initialized, which here is `new/1` on a
  fresh buffer, or until the stream is discarded.

  Every refusal names its rule (STANDARD.md "Refusal reasons"), and the
  stream latches the FIRST refusal's reason beside the flag: `refusal/1`
  reads it. The later refusals of a failed stream are echoes and keep it.
  """

  import Bitwise

  alias Serialize.{BitReader, Bits}

  defstruct data: <<>>, num_bits: 0, bits_read: 0, failed: false, refusal: nil

  @typedoc """
  The closed list of refusal reasons, spelled as STANDARD.md spells them.
  """
  @type refusal ::
          :past_end
          | :value_out_of_range
          | :nonzero_padding
          | :trailing_data
          | :non_finite_float
          | :invalid_utf8
          | :embedded_nul
          | :non_canonical

  @type t :: %__MODULE__{
          data: binary,
          num_bits: non_neg_integer,
          bits_read: non_neg_integer,
          failed: boolean,
          refusal: refusal | nil
        }

  @refusals [
    :past_end,
    :value_out_of_range,
    :nonzero_padding,
    :trailing_data,
    :non_finite_float,
    :invalid_utf8,
    :embedded_nul,
    :non_canonical
  ]

  @doc "The closed list of refusal reasons, in STANDARD.md's order."
  @spec refusals() :: [refusal]
  def refusals, do: @refusals

  @doc "A read stream over the given bytes. Re-initialization clears a latch."
  @spec new(binary) :: t
  def new(data) when is_binary(data) do
    %__MODULE__{data: data, num_bits: byte_size(data) * 8}
  end

  @doc """
  Latches the stream failed for `reason`, so every later read on it
  refuses. Callers refusing a read of their own — the operations in
  `Serialize` that decode above these primitives — latch through this. The
  first refusal's reason is kept: a stream that has already failed keeps
  the reason it failed for.
  """
  @spec fail(t, refusal) :: t
  def fail(%__MODULE__{failed: true} = stream, reason) when reason in @refusals, do: stream

  def fail(%__MODULE__{} = stream, reason) when reason in @refusals,
    do: %{stream | failed: true, refusal: reason}

  @doc "Whether a read on this stream has failed."
  @spec failed?(t) :: boolean
  def failed?(%__MODULE__{} = stream), do: stream.failed

  @doc "The first refusal's reason, or `nil` while no read has failed."
  @spec refusal(t) :: refusal | nil
  def refusal(%__MODULE__{} = stream), do: stream.refusal

  @doc """
  Reads a ranged 32-bit integer. The decoded offset must lie within the
  range — reject, never clamp.
  """
  @spec serialize_integer(t, term, integer, integer) :: {:ok, t, integer} | {:error, t}
  def serialize_integer(%__MODULE__{failed: true} = stream, _value, _min, _max),
    do: {:error, stream}

  def serialize_integer(%__MODULE__{} = stream, _value, min, max) do
    case read_offset(stream, Bits.bits_required(min, max)) do
      :degenerate ->
        {:ok, stream, min}

      {:error, stream} ->
        {:error, stream}

      {:ok, read, offset32} ->
        # offset form: compared against the span before the value is formed
        if offset32 > max - min do
          {:error, fail(read, :value_out_of_range)}
        else
          {:ok, read, min + offset32}
        end
    end
  end

  @doc "Reads a ranged 64-bit integer: low group first, then the remainder."
  @spec serialize_integer64(t, term, integer, integer) :: {:ok, t, integer} | {:error, t}
  def serialize_integer64(%__MODULE__{failed: true} = stream, _value, _min, _max),
    do: {:error, stream}

  def serialize_integer64(%__MODULE__{} = stream, _value, min, max) do
    case read_offset(stream, Bits.bits_required(min, max)) do
      :degenerate ->
        {:ok, stream, min}

      {:error, stream} ->
        {:error, stream}

      {:ok, read, offset64} ->
        if offset64 > max - min do
          {:error, fail(read, :value_out_of_range)}
        else
          {:ok, read, min + offset64}
        end
    end
  end

  @doc """
  Reads a ranged 128-bit integer: 32-bit groups from least significant
  upward, the final group carrying the remainder.
  """
  @spec serialize_integer128(t, term, integer, integer) :: {:ok, t, integer} | {:error, t}
  def serialize_integer128(%__MODULE__{failed: true} = stream, _value, _min, _max),
    do: {:error, stream}

  def serialize_integer128(%__MODULE__{} = stream, _value, min, max) do
    case read_offset(stream, Bits.bits_required(min, max)) do
      :degenerate ->
        {:ok, stream, min}

      {:error, stream} ->
        {:error, stream}

      {:ok, read, offset128} ->
        if offset128 > max - min do
          {:error, fail(read, :value_out_of_range)}
        else
          {:ok, read, min + offset128}
        end
    end
  end

  # The shared offset read: one up-front bounds check against the total
  # width (the reference's SerializeInteger/64/128 shape — a refused read
  # consumes nothing), then the offset in 32-bit groups from the bottom. A
  # degenerate range reads nothing. Each width keeps its own range check and
  # reconstruction above, the reference's shape and the sites its negative
  # controls name.
  defp read_offset(_stream, 0), do: :degenerate

  defp read_offset(stream, bits) do
    if stream.bits_read + bits > stream.num_bits do
      {:error, fail(stream, :past_end)}
    else
      {offset, bits_read} = read_groups(stream.data, stream.bits_read, bits, 0, 0)
      {:ok, %{stream | bits_read: bits_read}, offset}
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
  def serialize_bits(%__MODULE__{failed: true} = stream, _value, _bits), do: {:error, stream}

  def serialize_bits(%__MODULE__{} = stream, _value, bits) do
    if stream.bits_read + bits > stream.num_bits do
      {:error, fail(stream, :past_end)}
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
  def serialize_bytes(%__MODULE__{failed: true} = stream, _data, _count), do: {:error, stream}

  def serialize_bytes(%__MODULE__{} = stream, _data, count) do
    if count < 0 do
      {:error, fail(stream, :value_out_of_range)}
    else
      case serialize_align(stream) do
        {:error, stream} ->
          {:error, stream}

        {:ok, stream} ->
          # compared in bytes rather than bits, consistent with the
          # reference's 64-bit bookkeeping
          if count > div(stream.num_bits - stream.bits_read, 8) do
            {:error, fail(stream, :past_end)}
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
  def serialize_align(%__MODULE__{failed: true} = stream), do: {:error, stream}

  def serialize_align(%__MODULE__{} = stream) do
    case rem(stream.bits_read, 8) do
      0 ->
        {:ok, stream}

      remainder ->
        bits = 8 - remainder

        cond do
          stream.bits_read + bits > stream.num_bits ->
            {:error, fail(stream, :past_end)}

          BitReader.decode_bits(stream.data, stream.bits_read, bits) != 0 ->
            # the padding bits are consumed either way, as in the reference
            {:error, fail(%{stream | bits_read: stream.bits_read + bits}, :nonzero_padding)}

          true ->
            {:ok, %{stream | bits_read: stream.bits_read + bits}}
        end
    end
  end

  @doc """
  Reads the end of the object (STANDARD.md "end"): the stream ends at the
  bit index after the last field. A failed stream refuses with its first
  reason. Then a whole byte or more left over is `:trailing_data` — checked
  first, so it wins over the padding — and otherwise the 0 to 7 unused bits
  of the final byte must be zero, else `:nonzero_padding`. An accepted end
  consumes them, leaving the stream exactly consumed.
  """
  @spec serialize_end(t) :: {:ok, t} | {:error, t}
  def serialize_end(%__MODULE__{failed: true} = stream), do: {:error, stream}

  def serialize_end(%__MODULE__{} = stream) do
    remaining = stream.num_bits - stream.bits_read

    if remaining >= 8 do
      {:error, fail(stream, :trailing_data)}
    else
      read_end_padding(stream, remaining)
    end
  end

  defp read_end_padding(stream, 0), do: {:ok, stream}

  defp read_end_padding(stream, remaining) do
    padding = BitReader.decode_bits(stream.data, stream.bits_read, remaining)
    stream = %{stream | bits_read: stream.bits_read + remaining}

    if padding != 0 do
      {:error, fail(stream, :nonzero_padding)}
    else
      {:ok, stream}
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
