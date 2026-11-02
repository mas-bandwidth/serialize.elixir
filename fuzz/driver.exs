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
# Every read program runs twice across complementary caller-supplied initial
# values / sentinels (alt = false vs true), and continues invoking every
# remaining step after the first refusal to verify post-refusal terminality
# (each subsequent call must also return {:error, r2} with the first refusal
# reason and bits_processed unchanged). If post-refusal terminality fails, the
# driver reports reason `terminality:<reason>` so the differential goes red.
#
# A program is a sequence of lines:
#
#   W                 start a write program (the write stream grows)
#   R <hex>           start a read program over those bytes ("." is empty)
#   <op> <args...>    one serialize operation (see op/4 below)
#   END               finish: flush and report a write, or report a read

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

  defp run(["R " <> hex | rest], nil, out) do
    bytes = unhex(hex)
    r_a = ReadStream.new(bytes)
    r_b = ReadStream.new(bytes)
    run(rest, {:read, r_a, r_b, 0, [], false}, out)
  end

  defp run(["END" | rest], {:write, w, m}, out) do
    w = WriteStream.flush(w)

    line =
      "HEX #{hex(WriteStream.data(w))} #{Serialize.bits_processed(w)} #{Serialize.bits_processed(m)}\n"

    run(rest, nil, [line | out])
  end

  defp run(["END" | rest], {:read, r_a, r_b, n, tokens, term_broken}, out) do
    if ReadStream.failed?(r_a) != ReadStream.failed?(r_b) or
         Serialize.refusal(r_a) != Serialize.refusal(r_b) or
         Serialize.bits_processed(r_a) != Serialize.bits_processed(r_b) do
      raise("driver: two-sentinel read passes disagreed on stream state")
    end

    reason =
      if ReadStream.failed?(r_a) do
        first_refusal = Serialize.refusal(r_a)
        refused_bits = Serialize.bits_processed(r_a)
        probe_a = Serialize.serialize_bits(r_a, 0x5A5A5A5A, 1)
        probe_b = Serialize.serialize_bits(r_b, 0xA5A5A5A5, 1)

        probe_broken =
          case {probe_a, probe_b} do
            {{:error, r_a2}, {:error, r_b2}} ->
              Serialize.refusal(r_a2) != first_refusal or
                Serialize.refusal(r_b2) != first_refusal or
                Serialize.bits_processed(r_a2) != refused_bits or
                Serialize.bits_processed(r_b2) != refused_bits

            _ ->
              true
          end

        base = Atom.to_string(first_refusal)
        if term_broken or probe_broken, do: "terminality:" <> base, else: base
      else
        "ok"
      end

    line = Enum.join(["READ", Integer.to_string(n), reason | Enum.reverse(tokens)], " ") <> "\n"
    run(rest, nil, [line | out])
  end

  defp run([line | rest], {:write, w, m}, out) do
    [kind | args] = String.split(line, " ")
    {:ok, w, _value} = op(kind, w, args, false)
    {:ok, m, _value} = op(kind, m, args, false)
    run(rest, {:write, w, m}, out)
  end

  # A refused read is terminal: later ops are still invoked against the failed
  # stream so post-refusal terminality (refusal latch and bits_processed
  # invariance) is verified on every remaining step in the program.
  defp run([line | rest], {:read, r_a, r_b, n, tokens, term_broken}, out) do
    [kind | args] = String.split(line, " ")

    if ReadStream.failed?(r_a) do
      first_refusal = Serialize.refusal(r_a)
      refused_bits = Serialize.bits_processed(r_a)

      case {op(kind, r_a, args, false), op(kind, r_b, args, true)} do
        {{:error, r_a2}, {:error, r_b2}} ->
          broken =
            term_broken or
              Serialize.refusal(r_a2) != first_refusal or
              Serialize.refusal(r_b2) != first_refusal or
              Serialize.bits_processed(r_a2) != refused_bits or
              Serialize.bits_processed(r_b2) != refused_bits

          run(rest, {:read, r_a2, r_b2, n, tokens, broken}, out)

        _ ->
          run(rest, {:read, r_a, r_b, n, tokens, true}, out)
      end
    else
      case {op(kind, r_a, args, false), op(kind, r_b, args, true)} do
        {{:ok, r_a2, val_a}, {:ok, r_b2, val_b}} ->
          tok_a = token(kind, val_a)
          tok_b = token(kind, val_b)

          if tok_a != tok_b do
            raise("driver: two-sentinel read passes decoded different values for #{kind}")
          end

          run(rest, {:read, r_a2, r_b2, n + 1, [tok_a | tokens], term_broken}, out)

        {{:error, r_a2}, {:error, r_b2}} ->
          run(rest, {:read, r_a2, r_b2, n, tokens, term_broken}, out)

        _ ->
          raise("driver: two-sentinel read passes disagreed on #{kind}")
      end
    end
  end

  defp sentinel_int(%ReadStream{}, false, _v), do: 0x5A5A5A5A
  defp sentinel_int(%ReadStream{}, true, _v), do: -0x5A5A5A5B
  defp sentinel_int(_s, _alt, v), do: int(v)

  defp sentinel_bool(%ReadStream{}, alt, _v), do: alt
  defp sentinel_bool(_s, _alt, v), do: v == "1"

  defp sentinel_f32(%ReadStream{}, false, _bits), do: 1234.5
  defp sentinel_f32(%ReadStream{}, true, _bits), do: -5678.25
  defp sentinel_f32(_s, _alt, bits), do: f32(bits)

  defp sentinel_f64(%ReadStream{}, false, _bits), do: 1234.5
  defp sentinel_f64(%ReadStream{}, true, _bits), do: -5678.25
  defp sentinel_f64(_s, _alt, bits), do: Float32.value64(hexint(bits))

  defp sentinel_bin(%ReadStream{}, false, _data), do: <<0x5A, 0x5A, 0x5A, 0x5A>>
  defp sentinel_bin(%ReadStream{}, true, _data), do: <<0xA5, 0xA5, 0xA5, 0xA5>>
  defp sentinel_bin(_s, _alt, data), do: unhex(data)

  # Each op returns {:ok, stream, value} or {:error, stream}; align and end,
  # which carry no value, report "-".
  defp op("bits", s, [v, w], alt),
    do: Serialize.serialize_bits(s, sentinel_int(s, alt, v), int(w))

  defp op("bits64", s, [v, w], alt),
    do: Serialize.serialize_bits(s, sentinel_int(s, alt, v), int(w))

  defp op("bool", s, [v], alt),
    do: Serialize.serialize_bool(s, sentinel_bool(s, alt, v))

  defp op("u8", s, [v], alt),
    do: Serialize.serialize_uint8(s, sentinel_int(s, alt, v))

  defp op("u16", s, [v], alt),
    do: Serialize.serialize_uint16(s, sentinel_int(s, alt, v))

  defp op("u32", s, [v], alt),
    do: Serialize.serialize_uint32(s, sentinel_int(s, alt, v))

  defp op("u64", s, [v], alt),
    do: Serialize.serialize_uint64(s, sentinel_int(s, alt, v))

  defp op("u128", s, [v], alt),
    do: Serialize.serialize_uint128(s, sentinel_int(s, alt, v))

  defp op("int", s, [v, lo, hi], alt),
    do: Serialize.serialize_int(s, sentinel_int(s, alt, v), int(lo), int(hi))

  defp op("int64", s, [v, lo, hi], alt),
    do: Serialize.serialize_int64(s, sentinel_int(s, alt, v), int(lo), int(hi))

  defp op("i128", s, [v, lo, hi], alt),
    do: Serialize.serialize_int128(s, sentinel_int(s, alt, v), int(lo), int(hi))

  defp op(kind, s, [v, ib, fb, lo, hi], alt) when kind in ["fixed64", "fixed128"],
    do: Serialize.serialize_fixed(s, sentinel_int(s, alt, v), int(ib), int(fb), int(lo), int(hi))

  defp op("intrel", s, [prev, v], alt),
    do: Serialize.serialize_int_relative(s, int(prev), sentinel_int(s, alt, v))

  defp op("float", s, [bits], alt),
    do: Serialize.serialize_float(s, sentinel_f32(s, alt, bits))

  defp op("double", s, [bits], alt),
    do: Serialize.serialize_double(s, sentinel_f64(s, alt, bits))

  defp op("cfloat", s, [v, lo, hi, res], alt),
    do:
      Serialize.serialize_compressed_float(
        s,
        sentinel_f32(s, alt, v),
        f32(lo),
        f32(hi),
        f32(res)
      )

  defp op("bytes", s, [data, count], alt),
    do: Serialize.serialize_bytes(s, sentinel_bin(s, alt, data), int(count))

  defp op("str", s, [data, buffer_size], alt),
    do: Serialize.serialize_string(s, sentinel_bin(s, alt, data), int(buffer_size))

  defp op("align", s, [], _alt), do: no_value(Serialize.serialize_align(s))
  defp op("end", s, [], _alt), do: no_value(Serialize.serialize_end(s))

  # The object operation: a uint32 and a bool, composed as STANDARD.md's
  # serialize_object is (it contributes no bytes of its own).
  defp op("object", s, [u, b], alt) do
    with {:ok, s, u} <- Serialize.serialize_uint32(s, sentinel_int(s, alt, u)),
         {:ok, s, b} <- Serialize.serialize_bool(s, sentinel_bool(s, alt, b)) do
      {:ok, s, {u, b}}
    end
  end

  defp op(kind, _s, args, _alt), do: raise("driver: unknown op #{kind} #{inspect(args)}")

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
