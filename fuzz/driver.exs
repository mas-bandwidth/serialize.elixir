# fuzz/driver.exs: the Elixir half of the differential (fuzz/differential_test.go
# is the Go half). One BEAM start runs a whole batch file, given as the first
# argument, and prints one result line per program to stdout:
#
#   HEX <lowercase hex bytes> <bits written> <bits measured>
#                                  a written packet, with the write stream's bit
#                                  count and a measure stream's count over the
#                                  same program
#   READ <n> <reason> <token>...   a read: n ops accepted, the first refusal's
#                                  reason (STANDARD.md spelling, "ok" if none),
#                                  then the accepted ops' values
#
# A program is a sequence of lines:
#
#   W                 start a write program (the write stream grows)
#   R <hex>           start a read program over those bytes ("." is empty)
#   <op> <args...>    one serialize operation (see op/3 below)
#   END               finish: flush and report a write, or report a read
#
# Every integer crosses the process boundary in decimal (BEAM integers are
# exact at every width), every float as its IEEE-754 bit pattern in hex, and
# every byte string as hex, so nothing is lost to a float-vs-integer guess.
# Writes are strict: a write the library raises on crashes the driver, and the
# Go side reports that as a finding. A read stops at the first refusal.

defmodule Serialize.FuzzDriver do
  alias Serialize.{Float32, MeasureStream, ReadStream, WriteStream}

  def main([batch_file]) do
    batch_file
    |> File.read!()
    |> String.split("\n", trim: true)
    |> run(nil, [])
    |> Enum.reverse()
    |> IO.write()
  end

  defp run([], nil, out), do: out

  defp run(["W" | rest], nil, out),
    do: run(rest, {:write, WriteStream.new(), MeasureStream.new()}, out)

  defp run(["R " <> hex | rest], nil, out),
    do: run(rest, {:read, ReadStream.new(unhex(hex)), 0, []}, out)

  defp run(["END" | rest], {:write, w, m}, out) do
    w = WriteStream.flush(w)

    line =
      "HEX #{hex(WriteStream.data(w))} #{Serialize.bits_processed(w)} #{Serialize.bits_processed(m)}\n"

    run(rest, nil, [line | out])
  end

  defp run(["END" | rest], {:read, r, n, tokens}, out) do
    reason = if ReadStream.failed?(r), do: Atom.to_string(Serialize.refusal(r)), else: "ok"
    line = Enum.join(["READ", Integer.to_string(n), reason | Enum.reverse(tokens)], " ") <> "\n"
    run(rest, nil, [line | out])
  end

  defp run([line | rest], {:write, w, m}, out) do
    [kind | args] = String.split(line, " ")
    {:ok, w, _value} = op(kind, w, args)
    {:ok, m, _value} = op(kind, m, args)
    run(rest, {:write, w, m}, out)
  end

  # A refused read is terminal: later ops are not run, so n is the index of the
  # step that refused.
  defp run([line | rest], {:read, r, n, tokens} = state, out) do
    if ReadStream.failed?(r) do
      run(rest, state, out)
    else
      [kind | args] = String.split(line, " ")

      case op(kind, r, args) do
        {:ok, r, value} -> run(rest, {:read, r, n + 1, [token(kind, value) | tokens]}, out)
        {:error, r} -> run(rest, {:read, r, n, tokens}, out)
      end
    end
  end

  # Each op returns {:ok, stream, value} or {:error, stream}; align and end,
  # which carry no value, report "-".
  defp op("bits", s, [v, w]), do: Serialize.serialize_bits(s, int(v), int(w))
  defp op("bits64", s, [v, w]), do: Serialize.serialize_bits(s, int(v), int(w))
  defp op("bool", s, [v]), do: Serialize.serialize_bool(s, v == "1")
  defp op("u8", s, [v]), do: Serialize.serialize_uint8(s, int(v))
  defp op("u16", s, [v]), do: Serialize.serialize_uint16(s, int(v))
  defp op("u32", s, [v]), do: Serialize.serialize_uint32(s, int(v))
  defp op("u64", s, [v]), do: Serialize.serialize_uint64(s, int(v))
  defp op("u128", s, [v]), do: Serialize.serialize_uint128(s, int(v))
  defp op("int", s, [v, lo, hi]), do: Serialize.serialize_int(s, int(v), int(lo), int(hi))
  defp op("int64", s, [v, lo, hi]), do: Serialize.serialize_int64(s, int(v), int(lo), int(hi))
  defp op("i128", s, [v, lo, hi]), do: Serialize.serialize_int128(s, int(v), int(lo), int(hi))

  defp op(kind, s, [v, ib, fb, lo, hi]) when kind in ["fixed64", "fixed128"],
    do: Serialize.serialize_fixed(s, int(v), int(ib), int(fb), int(lo), int(hi))

  defp op("intrel", s, [prev, v]) do
    current = if match?(%ReadStream{}, s), do: nil, else: int(v)
    Serialize.serialize_int_relative(s, int(prev), current)
  end

  defp op("float", s, [bits]), do: Serialize.serialize_float(s, f32(bits))
  defp op("double", s, [bits]), do: Serialize.serialize_double(s, Float32.value64(hexint(bits)))

  defp op("cfloat", s, [v, lo, hi, res]),
    do: Serialize.serialize_compressed_float(s, f32(v), f32(lo), f32(hi), f32(res))

  defp op("bytes", s, [data, count]) do
    data = if match?(%ReadStream{}, s), do: nil, else: unhex(data)
    Serialize.serialize_bytes(s, data, int(count))
  end

  defp op("str", s, [data, buffer_size]) do
    data = if match?(%ReadStream{}, s), do: nil, else: unhex(data)
    Serialize.serialize_string(s, data, int(buffer_size))
  end

  defp op("align", s, []), do: no_value(Serialize.serialize_align(s))
  defp op("end", s, []), do: no_value(Serialize.serialize_end(s))

  # The object operation: a uint32 and a bool, composed as STANDARD.md's
  # serialize_object is (it contributes no bytes of its own).
  defp op("object", s, [u, b]) do
    with {:ok, s, u} <- Serialize.serialize_uint32(s, int(u)),
         {:ok, s, b} <- Serialize.serialize_bool(s, b == "1") do
      {:ok, s, {u, b}}
    end
  end

  defp op(kind, _s, args), do: raise("driver: unknown op #{kind} #{inspect(args)}")

  defp no_value({:ok, s}), do: {:ok, s, :none}
  defp no_value({:error, s}), do: {:error, s}

  defp token(kind, v) when kind in ["float", "cfloat"], do: hex32(Float32.bits32(v))
  defp token("double", v), do: Float32.bits64(v) |> Integer.to_string(16) |> pad(16)
  defp token("bool", v), do: if(v, do: "1", else: "0")
  defp token(kind, v) when kind in ["bytes", "str"], do: hex(v)
  defp token(kind, :none) when kind in ["align", "end"], do: "-"
  defp token("object", {u, b}), do: "#{u},#{if b, do: 1, else: 0}"
  defp token(_kind, v) when is_integer(v), do: Integer.to_string(v)

  defp int(s), do: String.to_integer(s)
  defp hexint(s), do: String.to_integer(s, 16)
  defp f32(bits), do: Float32.value32(hexint(bits))
  defp hex32(bits), do: bits |> Integer.to_string(16) |> pad(8)
  defp pad(s, n), do: s |> String.downcase() |> String.pad_leading(n, "0")

  defp hex(""), do: "."
  defp hex(bin), do: Base.encode16(bin, case: :lower)
  defp unhex("."), do: ""
  defp unhex(h), do: Base.decode16!(h, case: :mixed)
end

Serialize.FuzzDriver.main(System.argv())
