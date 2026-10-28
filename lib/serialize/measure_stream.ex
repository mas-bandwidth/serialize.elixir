defmodule Serialize.MeasureStream do
  @moduledoc """
  Stream for measuring how many bits a message would occupy: the
  measure-mode counterpart of the reference's `MeasureStream`.

  A measure is a bound, not the packet size (STANDARD.md "The Measure
  Stream"): every alignment-performing operation charges the worst-case
  7 bits, so the reported size is sufficient at any starting bit position,
  and everything else charges its exact width. A measure refuses nothing at
  runtime — it sits on the trusted side of the boundary — and holds the
  caller to the writer's contract: a value the write stream would raise on
  raises `ArgumentError` here too, the same trap, and nothing is ever
  latched (IMPLEMENTING.md U6, U9), so a measure is never taken of a
  message that cannot be written.

  The public surface here is `new/0` and the accessors. The measure
  primitives the unified operations in `Serialize` dispatch to are
  internal, `@doc false`, with no promise (IMPLEMENTING.md U15).
  """

  import Bitwise

  alias Serialize.Bits

  defstruct bits_written: 0

  @type t :: %__MODULE__{bits_written: non_neg_integer}

  @doc "A fresh measure with zero bits counted."
  @spec new() :: t
  def new, do: %__MODULE__{}

  # Internal, no promise (IMPLEMENTING.md U15).
  # Charges the exact width of a ranged 32-bit integer.
  @doc false
  @spec serialize_integer(t, integer, integer, integer) :: {:ok, t, integer}
  def serialize_integer(%__MODULE__{} = stream, value, min, max) do
    unless is_integer(value) and value >= min and value <= max do
      raise ArgumentError, "serialize_int value #{inspect(value)} outside [#{min}, #{max}]"
    end

    {:ok, add(stream, Bits.bits_required(min, max)), value}
  end

  # Internal, no promise (IMPLEMENTING.md U15).
  # Charges the exact width of a ranged 64-bit integer.
  @doc false
  @spec serialize_integer64(t, integer, integer, integer) :: {:ok, t, integer}
  def serialize_integer64(%__MODULE__{} = stream, value, min, max) do
    unless is_integer(value) and value >= min and value <= max do
      raise ArgumentError, "serialize_int64 value #{inspect(value)} outside [#{min}, #{max}]"
    end

    {:ok, add(stream, Bits.bits_required(min, max)), value}
  end

  # Internal, no promise (IMPLEMENTING.md U15).
  # Charges the exact width of a ranged 128-bit integer.
  @doc false
  @spec serialize_integer128(t, integer, integer, integer) :: {:ok, t, integer}
  def serialize_integer128(%__MODULE__{} = stream, value, min, max) do
    unless is_integer(value) and value >= min and value <= max do
      raise ArgumentError, "serialize_int128 value #{inspect(value)} outside [#{min}, #{max}]"
    end

    {:ok, add(stream, Bits.bits_required(min, max)), value}
  end

  # Internal, no promise (IMPLEMENTING.md U15).
  # Charges `bits` bits, `bits` in `[1, 32]`.
  @doc false
  @spec serialize_bits(t, non_neg_integer, 1..32) :: {:ok, t, non_neg_integer}
  def serialize_bits(%__MODULE__{} = stream, value, bits) do
    unless is_integer(value) and value >= 0 and value <= (1 <<< bits) - 1 do
      raise ArgumentError, "serialize_bits value #{inspect(value)} does not fit #{bits} bits"
    end

    {:ok, add(stream, bits), value}
  end

  # Internal, no promise (IMPLEMENTING.md U15).
  # Charges the worst-case align, then `count` whole bytes.
  @doc false
  @spec serialize_bytes(t, binary, non_neg_integer) :: {:ok, t, binary}
  def serialize_bytes(%__MODULE__{} = stream, data, count) do
    unless is_binary(data) and byte_size(data) == count do
      raise ArgumentError, "serialize_bytes data does not match count #{inspect(count)}"
    end

    {:ok, stream} = serialize_align(stream)
    {:ok, add(stream, count * 8), data}
  end

  # Internal, no promise (IMPLEMENTING.md U15).
  # Charges the worst-case align: always 7 bits.
  @doc false
  @spec serialize_align(t) :: {:ok, t}
  def serialize_align(%__MODULE__{} = stream), do: {:ok, add(stream, 7)}

  # Internal, no promise (IMPLEMENTING.md U15).
  # Charges the end of the object: nothing.
  @doc false
  @spec serialize_end(t) :: {:ok, t}
  def serialize_end(%__MODULE__{} = stream), do: {:ok, stream}

  @doc """
  The worst-case align cost: always 7, because the bit position a message
  is later written at is unknown to a measure.
  """
  @spec align_bits(t) :: 7
  def align_bits(%__MODULE__{}), do: 7

  @doc "The number of bits counted so far."
  @spec bits_processed(t) :: non_neg_integer
  def bits_processed(%__MODULE__{} = stream), do: stream.bits_written

  @doc "The number of bytes counted so far: the bit count rounded up."
  @spec bytes_processed(t) :: non_neg_integer
  def bytes_processed(%__MODULE__{} = stream), do: div(stream.bits_written + 7, 8)

  defp add(stream, bits), do: %{stream | bits_written: stream.bits_written + bits}
end
