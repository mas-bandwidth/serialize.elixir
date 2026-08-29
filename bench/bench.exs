# serialize.elixir benchmark.
#
# A deliberate operation-for-operation mirror of serialize.c's bench.c --
# itself a mirror of the C++ library's bench.cpp -- so the outputs of all the
# family's benchmarks can be read side by side. Same operations in the same
# order, same iteration counts, same buffer sizes, same LCG-driven input
# data, same best-of-five-trials discipline, same reporting format and units.
#
#   mix run bench/bench.exs           the rows, human readable
#   mix run bench/bench.exs --csv     the same numbers as CSV: row,op,units,value
#
# The library and this bench compile with default mix settings -- the number a
# user gets. BeamAsm compiles every module at load, so there is no tiered
# warmup to wait out; one untimed pass of each leg runs before its five timed
# trials anyway.
#
# Iteration counts are overridable so the harness can be run at a different
# scale and the timings checked for linearity -- a benchmark whose loop has
# been optimized away does not scale with its iteration count:
#
#   BENCH_BITPACKER_PASSES=256 BENCH_STREAM_PACKETS=100000 mix run bench/bench.exs
#
# GOLDEN GATED: before any row is timed, the exact buffers its loops write
# are verified byte for byte against pins produced by serialize.c's own bench
# data paths (the same pins the JavaScript, Dart and Java benches carry). The
# LCG is the C bench's uint64 LCG, run directly in BEAM integers under an
# explicit 64-bit mask: variant 0 diverges on any error in a single step, and
# variant 63 diverges on any error anywhere in 64 chained steps, in any field,
# in any serialize operation. The read leg then decodes every variant buffer
# and verifies every field. A bench that fails its goldens reports nothing.
#
# WHAT IS DELIBERATELY NOT MIRRORED
#
# bench.cpp's compile time rows (its template parameter surface) have no
# counterpart here, the same omission serialize.c makes. Where bench.c writes
# separate write/read/measure functions per shape, this bench writes ONE
# serialize function per shape -- a `with` chain over the unified operations,
# run against all three streams: the family's defining pattern, and exactly
# what generated Elixir looks like. Two costs are structural and deliberately
# left visible rather than benched around: streams are immutable, so every
# packet constructs a fresh stream and every operation returns a new one (the
# library's own surface, measured as shipped), and the decoded packet is
# rebuilt as a new map per packet, exactly as generated Elixir returns it.
# Writes always validate their caller contract -- the library has no separate
# release shape -- so the checked variant is the only variant.
#
# Only numbers from a quiet machine are meaningful, and only as ratios
# between family legs measured back to back on the same machine.

defmodule Bench do
  import Bitwise

  alias Serialize.{BitReader, BitWriter, MeasureStream, ReadStream, WriteStream}

  @num_trials 5
  @num_variants 64

  @bitpacker_buffer_size 64 * 1024
  @bitpacker_capacity_bits @bitpacker_buffer_size * 8

  # ------------------------------------------------------------------
  # the C bench's uint64 LCG, direct in BEAM integers under a 64-bit mask
  # ------------------------------------------------------------------

  @mask64 0xFFFFFFFFFFFFFFFF
  @lcg_mul 6_364_136_223_846_793_005
  @lcg_add 1_442_695_040_888_963_407

  defp lcg_seed, do: 1

  defp lcg_step(rng), do: rng * @lcg_mul + @lcg_add &&& @mask64

  # the low 32 bits of (rng >> s), the JS bench's shr64
  defp shr(rng, s), do: rng >>> s &&& 0xFFFFFFFF

  # ------------------------------------------------------------------
  # pins
  #
  # Produced by serialize.c's own bench data paths (its static vary and
  # write functions, run to the letter): the bitpacker's pass buffer, and
  # for each packet shape the first and last of the 64 variant buffers the
  # read leg decodes. Byte identical across the family, so these gate this
  # bench's wire against the C reference, not against itself.
  # ------------------------------------------------------------------

  @pin_bitpacker %{
    bytes_per_pass: 65_518,
    first64:
      "e5e6dd7856e4a656da4c1f909b173ac12a3e2f56da3c5011ce0b72f32e37efc6" <>
        "b32237b5d266fa80dcbcd00956f179b1d2e6818a705e909b77b979379e15b9a9",
    last8: "cd0315e1bc20376f"
  }

  @pin_stream %{
    bytes_per_packet: 49,
    variant0:
      "44fd43634d97ff0006d03f0000f0850000a08001809085f800fa8758dfaed800ac1f3e5d7c9bbad9f81736557493b2d1f0",
    variant63:
      "7e6bc3e30c348874a5bb360182748e0000a080018090858274d786d778b6ae016b1f3e5d7c9bbad9f81736557493b2d1f0"
  }

  @pin_int %{
    bytes_per_packet: 14,
    variant0: "44fd43634df7f390f5be45153d1b",
    variant63: "7e6bc3e30c14d7508df23ce1b915"
  }

  @pin_bits %{
    bytes_per_packet: 20,
    variant0: "fc073080fe51ff10eb5bdfec8acd07d03fc4fa06",
    variant63: "41a42bddb5f1daf01acf7866eb1aa4bb36bcc603"
  }

  @pin_gen %{
    bytes_per_packet: 21,
    variant0: "00fdfd43ac6f7cf0430cb1c6fa1ec007d03fc4fa66",
    variant63: "ba6b6bc36b3c416ac30bafbdc69116a4bb36bcc6d3"
  }

  # ------------------------------------------------------------------
  # harness
  # ------------------------------------------------------------------

  defp env_int(name, fallback) do
    case System.get_env(name) do
      nil ->
        fallback

      raw ->
        case Integer.parse(raw) do
          {value, ""} when value >= 1 ->
            value

          _ ->
            IO.write(:stderr, "#{name} must be a positive integer\n")
            System.halt(1)
        end
    end
  end

  defp gate_fail(row, what, expected, got) do
    IO.write(
      :stderr,
      "GOLDEN GATE FAILED: #{row} #{what}\n  expected #{expected}\n  got      #{got}\n"
    )

    IO.write(:stderr, "reporting nothing.\n")
    System.halt(1)
  end

  defp to_hex(data), do: Base.encode16(data, case: :lower)

  defp fmt(value, decimals), do: :erlang.float_to_binary(value * 1.0, decimals: decimals)

  defp pad(value, width), do: String.pad_leading(value, width)

  # ------------------------------------------------------------------
  # bitpacker
  #
  # The raw bit packer with mixed widths: 227 bits per group of 16 writes,
  # repeated until fewer than 256 bits remain of a 64KB buffer's capacity.
  # ------------------------------------------------------------------

  @bitpacker_widths [1, 32, 7, 13, 3, 25, 8, 19, 4, 28, 11, 16, 2, 30, 6, 22]

  @bitpacker_pairs @bitpacker_widths
                   |> Enum.with_index()
                   |> Enum.map(fn {width, i} ->
                     {0x9E3779B9 * (i + 1) &&& 0xFFFFFFFF &&& (1 <<< width) - 1, width}
                   end)

  defp write_group(writer, []), do: writer

  defp write_group(writer, [{value, width} | rest]) do
    write_group(BitWriter.write_bits(writer, value, width), rest)
  end

  defp write_pass(writer) do
    if @bitpacker_capacity_bits - BitWriter.bits_written(writer) >= 256 do
      write_pass(write_group(writer, @bitpacker_pairs))
    else
      BitWriter.flush(writer)
    end
  end

  defp read_group(reader, [], sum), do: {sum, reader}

  defp read_group(reader, [{_value, width} | rest], sum) do
    {value, reader} = BitReader.read_bits(reader, width)
    read_group(reader, rest, sum + value)
  end

  defp read_pass(reader, sum) do
    if BitReader.bits_remaining(reader) >= 256 do
      {sum, reader} = read_group(reader, @bitpacker_pairs, sum)
      read_pass(reader, sum)
    else
      sum
    end
  end

  # One pass, held byte for byte against the C reference, then read back in
  # full. Returns the written pass bytes for the timing loops.
  defp gate_bitpacker do
    writer = write_pass(BitWriter.new())
    bytes_per_pass = BitWriter.bytes_written(writer)
    data = BitWriter.data(writer)

    if bytes_per_pass != @pin_bitpacker.bytes_per_pass do
      gate_fail(
        "bitpacker",
        "bytes per pass",
        "#{@pin_bitpacker.bytes_per_pass}",
        "#{bytes_per_pass}"
      )
    end

    first64 = to_hex(binary_part(data, 0, 64))

    if first64 != @pin_bitpacker.first64 do
      gate_fail("bitpacker", "first 64 bytes", @pin_bitpacker.first64, first64)
    end

    last8 = to_hex(binary_part(data, bytes_per_pass - 8, 8))

    if last8 != @pin_bitpacker.last8 do
      gate_fail("bitpacker", "last 8 bytes", @pin_bitpacker.last8, last8)
    end

    gate_read_pass(BitReader.new(data))

    data
  end

  defp gate_read_pass(reader) do
    if BitReader.bits_remaining(reader) >= 256 do
      reader = gate_read_group(reader, @bitpacker_pairs)
      gate_read_pass(reader)
    else
      :ok
    end
  end

  defp gate_read_group(reader, []), do: reader

  defp gate_read_group(reader, [{expected, width} | rest]) do
    case BitReader.read_bits(reader, width) do
      {^expected, reader} -> gate_read_group(reader, rest)
      {value, _reader} -> gate_fail("bitpacker", "read back", "#{expected}", "#{value}")
    end
  end

  defp bitpacker_write_loop(0, acc), do: acc

  defp bitpacker_write_loop(passes, acc) do
    writer = write_pass(BitWriter.new())
    bitpacker_write_loop(passes - 1, acc + BitWriter.bytes_written(writer))
  end

  defp bitpacker_read_loop(0, _data, acc), do: acc

  defp bitpacker_read_loop(passes, data, acc) do
    sum = read_pass(BitReader.new(data), 0)
    bitpacker_read_loop(passes - 1, data, acc + sum)
  end

  defp bench_bitpacker(data, passes) do
    bytes_per_pass = @pin_bitpacker.bytes_per_pass

    {best_write, best_read, sink} =
      Enum.reduce(0..@num_trials, {nil, nil, 0}, fn trial, {best_write, best_read, sink} ->
        t0 = System.monotonic_time(:nanosecond)
        sink_w = bitpacker_write_loop(passes, 0)
        write_ns = System.monotonic_time(:nanosecond) - t0

        t0 = System.monotonic_time(:nanosecond)
        sink_r = bitpacker_read_loop(passes, data, 0)
        read_ns = System.monotonic_time(:nanosecond) - t0

        if trial == 0 do
          # the untimed warmup pass
          {best_write, best_read, sink + sink_w + sink_r}
        else
          {best_of(best_write, write_ns), best_of(best_read, read_ns), sink + sink_w + sink_r}
        end
      end)

    total_mb = bytes_per_pass * passes / (1024 * 1024)
    write_mbs = total_mb / (best_write * 1.0e-9)
    read_mbs = total_mb / (best_read * 1.0e-9)

    {[
       {"bitpacker", "write", "MB/s", write_mbs},
       {"bitpacker", "read", "MB/s", read_mbs}
     ],
     [
       "bitpacker write:  #{pad(fmt(write_mbs, 1), 8)} MB/s\n",
       "bitpacker read:   #{pad(fmt(read_mbs, 1), 8)} MB/s\n"
     ], sink}
  end

  defp best_of(nil, ns), do: ns
  defp best_of(best, ns), do: min(best, ns)

  # ------------------------------------------------------------------
  # packet shapes
  #
  # Each shape is one serialize function run against all three streams, a
  # vary function that drives most fields from the serially dependent LCG
  # the runtime cannot fold, and map equality for the read gate. The vary
  # functions rebuild the packet map from the stepped LCG -- allocation the
  # C bench does not pay, but the exact shape a BEAM caller's data takes.
  # ------------------------------------------------------------------

  # shape: the representative stream packet (ints, bits, bool, floats,
  # uint64, bytes)

  @blob_init for i <- 0..16, into: <<>>, do: <<i * 31 &&& 0xFF>>
  @blob_tail binary_part(@blob_init, 1, 16)

  defp init_bench_packet do
    %{
      a: -37,
      b: 12_345,
      c: 987_654,
      bits7: 97,
      bits13: 5000,
      bits23: 1_234_567,
      flag: true,
      x: 1.5,
      y: -3.25,
      z: 100.125,
      big: 0x123456789ABCDEF0,
      blob: @blob_init
    }
  end

  defp vary_bench_packet(p, rng) do
    %{
      p
      | a: (shr(rng, 8) &&& 63) - 32,
        b: shr(rng, 16) &&& 65_535,
        c: (shr(rng, 24) &&& 0xFFFFF) - 500_000,
        bits7: rng &&& 127,
        bits13: shr(rng, 3) &&& 8191,
        bits23: shr(rng, 5) &&& 8_388_607,
        flag: (rng &&& 1) != 0,
        # exact in float32
        x: (rng &&& 0xFFFF) * 1.0,
        big: rng,
        blob: <<rng >>> 32 &&& 0xFF, @blob_tail::binary>>
    }
  end

  defp serialize_bench_packet(stream, p) do
    with {:ok, stream, a} <- Serialize.serialize_int(stream, p.a, -100, 100),
         {:ok, stream, b} <- Serialize.serialize_int(stream, p.b, 0, 65_535),
         {:ok, stream, c} <- Serialize.serialize_int(stream, p.c, -1_000_000, 1_000_000),
         {:ok, stream, bits7} <- Serialize.serialize_bits(stream, p.bits7, 7),
         {:ok, stream, bits13} <- Serialize.serialize_bits(stream, p.bits13, 13),
         {:ok, stream, bits23} <- Serialize.serialize_bits(stream, p.bits23, 23),
         {:ok, stream, flag} <- Serialize.serialize_bool(stream, p.flag),
         {:ok, stream, x} <- Serialize.serialize_float(stream, p.x),
         {:ok, stream, y} <- Serialize.serialize_float(stream, p.y),
         {:ok, stream, z} <- Serialize.serialize_float(stream, p.z),
         {:ok, stream, big} <- Serialize.serialize_uint64(stream, p.big),
         {:ok, stream, blob} <- Serialize.serialize_bytes(stream, p.blob, 17) do
      {:ok, stream,
       %{
         a: a,
         b: b,
         c: c,
         bits7: bits7,
         bits13: bits13,
         bits23: bits23,
         flag: flag,
         x: x,
         y: y,
         z: z,
         big: big,
         blob: blob
       }}
    end
  end

  # shape 1: a realistic packet of ten bounded ints

  defp init_int_fields do
    %{f0: 0, f1: 0, f2: 0, f3: 0, f4: 0, f5: 0, f6: 0, f7: 0, f8: 0, f9: 0}
  end

  defp vary_int_fields(_p, rng) do
    %{
      f0: (shr(rng, 8) &&& 63) - 32,
      f1: shr(rng, 16) &&& 65_535,
      f2: (shr(rng, 24) &&& 0xFFFFF) - 500_000,
      f3: shr(rng, 2) &&& 3,
      f4: (shr(rng, 11) &&& 15) - 8,
      f5: shr(rng, 22) &&& 511,
      f6: (shr(rng, 33) &&& 2047) - 1024,
      f7: shr(rng, 40) &&& 255,
      f8: (shr(rng, 30) &&& 0xFFFFF) - 500_000,
      f9: shr(rng, 57) &&& 63
    }
  end

  defp serialize_int_fields(stream, p) do
    with {:ok, stream, f0} <- Serialize.serialize_int(stream, p.f0, -100, 100),
         {:ok, stream, f1} <- Serialize.serialize_int(stream, p.f1, 0, 65_535),
         {:ok, stream, f2} <- Serialize.serialize_int(stream, p.f2, -1_000_000, 1_000_000),
         {:ok, stream, f3} <- Serialize.serialize_int(stream, p.f3, 0, 3),
         {:ok, stream, f4} <- Serialize.serialize_int(stream, p.f4, -15, 15),
         {:ok, stream, f5} <- Serialize.serialize_int(stream, p.f5, 0, 1000),
         {:ok, stream, f6} <- Serialize.serialize_int(stream, p.f6, -2048, 2047),
         {:ok, stream, f7} <- Serialize.serialize_int(stream, p.f7, 0, 255),
         {:ok, stream, f8} <- Serialize.serialize_int(stream, p.f8, -600_000, 600_000),
         {:ok, stream, f9} <- Serialize.serialize_int(stream, p.f9, 0, 100) do
      {:ok, stream,
       %{f0: f0, f1: f1, f2: f2, f3: f3, f4: f4, f5: f5, f6: f6, f7: f7, f8: f8, f9: f9}}
    end
  end

  # shape 2: mixed bit widths including one wider than 32 bits. The 48-bit
  # field travels as its low dword then the 16-bit remainder in two lanes --
  # STANDARD.md's splitting rule, keeping a hot timestamp in two 32-bit
  # groups exactly as the family's generated code writes it.

  defp init_bits_fields do
    %{b7: 0, b13: 0, b23: 0, b3: 0, b32: 0, b11: 0, b19: 0, b48lo: 0, b48hi: 0}
  end

  defp vary_bits_fields(_p, rng) do
    %{
      b7: rng &&& 127,
      b13: shr(rng, 3) &&& 8191,
      b23: shr(rng, 5) &&& 8_388_607,
      b3: shr(rng, 29) &&& 7,
      b32: shr(rng, 16),
      b11: shr(rng, 37) &&& 2047,
      b19: shr(rng, 44) &&& 524_287,
      b48lo: rng &&& 0xFFFFFFFF,
      b48hi: rng >>> 32 &&& 0xFFFF
    }
  end

  defp serialize_bits_fields(stream, p) do
    with {:ok, stream, b7} <- Serialize.serialize_bits(stream, p.b7, 7),
         {:ok, stream, b13} <- Serialize.serialize_bits(stream, p.b13, 13),
         {:ok, stream, b23} <- Serialize.serialize_bits(stream, p.b23, 23),
         {:ok, stream, b3} <- Serialize.serialize_bits(stream, p.b3, 3),
         {:ok, stream, b32} <- Serialize.serialize_bits(stream, p.b32, 32),
         {:ok, stream, b11} <- Serialize.serialize_bits(stream, p.b11, 11),
         {:ok, stream, b19} <- Serialize.serialize_bits(stream, p.b19, 19),
         {:ok, stream, b48lo} <- Serialize.serialize_bits(stream, p.b48lo, 32),
         {:ok, stream, b48hi} <- Serialize.serialize_bits(stream, p.b48hi, 16) do
      {:ok, stream,
       %{
         b7: b7,
         b13: b13,
         b23: b23,
         b3: b3,
         b32: b32,
         b11: b11,
         b19: b19,
         b48lo: b48lo,
         b48hi: b48hi
       }}
    end
  end

  # shape 3: a "generated packet" mixing bounded ints, bits and bools, the
  # way schema generated code looks. The 48-bit timestamp travels in two
  # lanes.

  defp init_gen_fields do
    %{
      sequence: 0,
      ack_bits: 0,
      entity_id: 0,
      pos_x: 0,
      pos_y: 0,
      pos_z: 0,
      yaw: 0,
      moving: false,
      firing: false,
      timestamp_lo: 0,
      timestamp_hi: 0,
      weapon: 0
    }
  end

  defp vary_gen_fields(_p, rng) do
    %{
      sequence: shr(rng, 8) &&& 65_535,
      ack_bits: shr(rng, 16),
      entity_id: rng &&& 4095,
      pos_x: (shr(rng, 20) &&& 32_767) - 16_384,
      pos_y: (shr(rng, 25) &&& 32_767) - 16_384,
      pos_z: (shr(rng, 30) &&& 32_767) - 16_384,
      yaw: shr(rng, 3) &&& 511,
      moving: (rng &&& 1) != 0,
      firing: (rng &&& 2) != 0,
      timestamp_lo: rng &&& 0xFFFFFFFF,
      timestamp_hi: rng >>> 32 &&& 0xFFFF,
      weapon: shr(rng, 60) &&& 15
    }
  end

  defp serialize_gen_fields(stream, p) do
    with {:ok, stream, sequence} <- Serialize.serialize_int(stream, p.sequence, 0, 65_535),
         {:ok, stream, ack_bits} <- Serialize.serialize_bits(stream, p.ack_bits, 32),
         {:ok, stream, entity_id} <- Serialize.serialize_bits(stream, p.entity_id, 12),
         {:ok, stream, pos_x} <- Serialize.serialize_int(stream, p.pos_x, -16_384, 16_383),
         {:ok, stream, pos_y} <- Serialize.serialize_int(stream, p.pos_y, -16_384, 16_383),
         {:ok, stream, pos_z} <- Serialize.serialize_int(stream, p.pos_z, -16_384, 16_383),
         {:ok, stream, yaw} <- Serialize.serialize_bits(stream, p.yaw, 9),
         {:ok, stream, moving} <- Serialize.serialize_bool(stream, p.moving),
         {:ok, stream, firing} <- Serialize.serialize_bool(stream, p.firing),
         {:ok, stream, timestamp_lo} <- Serialize.serialize_bits(stream, p.timestamp_lo, 32),
         {:ok, stream, timestamp_hi} <- Serialize.serialize_bits(stream, p.timestamp_hi, 16),
         {:ok, stream, weapon} <- Serialize.serialize_int(stream, p.weapon, 0, 15) do
      {:ok, stream,
       %{
         sequence: sequence,
         ack_bits: ack_bits,
         entity_id: entity_id,
         pos_x: pos_x,
         pos_y: pos_y,
         pos_z: pos_z,
         yaw: yaw,
         moving: moving,
         firing: firing,
         timestamp_lo: timestamp_lo,
         timestamp_hi: timestamp_hi,
         weapon: weapon
       }}
    end
  end

  # ------------------------------------------------------------------
  # variant generation and the golden gate, shared by every packet shape
  # ------------------------------------------------------------------

  # Pre-writes the 64 variant buffers the read leg decodes, using the same
  # LCG sequence as the write loop, then holds the wire against the C pins
  # and decodes every variant back, verifying every field. Returns the
  # variants as a tuple and the constant per-packet byte size.
  defp gate_shape(row, init, vary, serialize, pin) do
    {variants, _rng, _p} =
      Enum.reduce(1..@num_variants, {[], lcg_seed(), init}, fn _, {variants, rng, p} ->
        rng = lcg_step(rng)
        p = vary.(p, rng)
        stream = WriteStream.new()

        case serialize.(stream, p) do
          {:ok, stream, _} ->
            stream = WriteStream.flush(stream)
            {[WriteStream.data(stream) | variants], rng, p}

          {:error, _stream} ->
            gate_fail(row, "variant write", "ok", "error")
        end
      end)

    variants = Enum.reverse(variants)
    bytes_per_packet = byte_size(hd(variants))

    if bytes_per_packet != pin.bytes_per_packet do
      gate_fail(row, "bytes per packet", "#{pin.bytes_per_packet}", "#{bytes_per_packet}")
    end

    hex0 = to_hex(Enum.at(variants, 0))

    if hex0 != pin.variant0 do
      gate_fail(row, "variant 0 wire", pin.variant0, hex0)
    end

    hex63 = to_hex(Enum.at(variants, 63))

    if hex63 != pin.variant63 do
      gate_fail(row, "variant 63 wire", pin.variant63, hex63)
    end

    # decode every variant and verify every field against a replay of the LCG
    {_rng, _p} =
      variants
      |> Enum.with_index()
      |> Enum.reduce({lcg_seed(), init}, fn {variant, k}, {rng, p} ->
        rng = lcg_step(rng)
        p = vary.(p, rng)

        case serialize.(ReadStream.new(variant), p) do
          {:ok, _stream, decoded} ->
            if decoded != p do
              gate_fail(row, "variant #{k} fields", "writer values", "different values")
            end

            {rng, p}

          {:error, _stream} ->
            gate_fail(row, "variant #{k} decode", "ok", "error")
        end
      end)

    {List.to_tuple(variants), bytes_per_packet}
  end

  # ------------------------------------------------------------------
  # stream
  #
  # The representative packet through all three streams: MB/s and
  # M packets/s for write and read, M packets/s for measure.
  # ------------------------------------------------------------------

  defp gate_stream do
    {variants, bytes_per_packet} =
      gate_shape(
        "stream",
        init_bench_packet(),
        &vary_bench_packet/2,
        &serialize_bench_packet/2,
        @pin_stream
      )

    # measure gate: the measured bits equal the written bits for this packet
    {:ok, measure, _} = serialize_bench_packet(MeasureStream.new(), init_bench_packet())

    if MeasureStream.bytes_processed(measure) != bytes_per_packet do
      gate_fail(
        "stream",
        "measure bytes",
        "#{bytes_per_packet}",
        "#{MeasureStream.bytes_processed(measure)}"
      )
    end

    {variants, bytes_per_packet}
  end

  defp stream_write_loop(0, rng, _p, acc), do: {acc, rng}

  defp stream_write_loop(n, rng, p, acc) do
    rng = lcg_step(rng)
    p = vary_bench_packet(p, rng)
    {:ok, stream, _} = serialize_bench_packet(WriteStream.new(), p)
    stream = WriteStream.flush(stream)
    stream_write_loop(n - 1, rng, p, acc + WriteStream.bytes_processed(stream))
  end

  defp stream_read_loop(0, _i, _variants, _template, acc), do: acc

  defp stream_read_loop(n, i, variants, template, acc) do
    variant = elem(variants, i &&& @num_variants - 1)
    {:ok, _stream, decoded} = serialize_bench_packet(ReadStream.new(variant), template)
    stream_read_loop(n - 1, i + 1, variants, template, acc + decoded.b)
  end

  defp stream_measure_loop(0, _rng, _p, acc), do: acc

  defp stream_measure_loop(n, rng, p, acc) do
    rng = lcg_step(rng)
    p = vary_bench_packet(p, rng)
    {:ok, measure, _} = serialize_bench_packet(MeasureStream.new(), p)
    stream_measure_loop(n - 1, rng, p, acc + MeasureStream.bits_processed(measure))
  end

  defp bench_stream({variants, bytes_per_packet}, num_packets) do
    template = init_bench_packet()

    {best_write, best_read, best_measure, sink} =
      Enum.reduce(0..@num_trials, {nil, nil, nil, 0}, fn trial, {bw, br, bm, sink} ->
        t0 = System.monotonic_time(:nanosecond)
        {sink_w, rng} = stream_write_loop(num_packets, lcg_seed(), init_bench_packet(), 0)
        write_ns = System.monotonic_time(:nanosecond) - t0

        t0 = System.monotonic_time(:nanosecond)
        sink_r = stream_read_loop(num_packets, 0, variants, template, 0)
        read_ns = System.monotonic_time(:nanosecond) - t0

        # measure prices the packet without touching memory; that it is
        # nearly free is the property worth tracking. The vary call stays so
        # the loop is the loop the other family benches time; the LCG
        # continues from the write loop's state, as in the C bench.
        t0 = System.monotonic_time(:nanosecond)
        sink_m = stream_measure_loop(num_packets, rng, init_bench_packet(), 0)
        measure_ns = System.monotonic_time(:nanosecond) - t0

        sink = sink + sink_w + sink_r + sink_m

        if trial == 0 do
          {bw, br, bm, sink}
        else
          {best_of(bw, write_ns), best_of(br, read_ns), best_of(bm, measure_ns), sink}
        end
      end)

    total_mb = bytes_per_packet * num_packets / (1024 * 1024)
    packets = num_packets / 1_000_000

    write_mbs = total_mb / (best_write * 1.0e-9)
    write_mpps = packets / (best_write * 1.0e-9)
    read_mbs = total_mb / (best_read * 1.0e-9)
    read_mpps = packets / (best_read * 1.0e-9)
    measure_mpps = packets / (best_measure * 1.0e-9)

    {[
       {"stream", "write", "MB/s", write_mbs},
       {"stream", "write", "Mpackets/s", write_mpps},
       {"stream", "read", "MB/s", read_mbs},
       {"stream", "read", "Mpackets/s", read_mpps},
       {"stream", "measure", "Mpackets/s", measure_mpps}
     ],
     [
       "stream write:     #{pad(fmt(write_mbs, 1), 8)} MB/s  (#{fmt(write_mpps, 1)} M packets/s)\n",
       "stream read:      #{pad(fmt(read_mbs, 1), 8)} MB/s  (#{fmt(read_mpps, 1)} M packets/s)\n",
       "stream measure:   #{pad(fmt(measure_mpps, 1), 19)} M packets/s\n"
     ], sink}
  end

  # ------------------------------------------------------------------
  # packet shapes: write and read, M packets/s
  # ------------------------------------------------------------------

  defp shape_write_loop(0, _rng, _p, _vary, _serialize, acc), do: acc

  defp shape_write_loop(n, rng, p, vary, serialize, acc) do
    rng = lcg_step(rng)
    p = vary.(p, rng)
    {:ok, stream, _} = serialize.(WriteStream.new(), p)
    stream = WriteStream.flush(stream)
    shape_write_loop(n - 1, rng, p, vary, serialize, acc + WriteStream.bytes_processed(stream))
  end

  defp shape_read_loop(0, _i, _variants, _template, _serialize, _sink_of, acc), do: acc

  defp shape_read_loop(n, i, variants, template, serialize, sink_of, acc) do
    variant = elem(variants, i &&& @num_variants - 1)
    {:ok, _stream, decoded} = serialize.(ReadStream.new(variant), template)
    shape_read_loop(n - 1, i + 1, variants, template, serialize, sink_of, acc + sink_of.(decoded))
  end

  defp bench_shape(row, label, {variants, _bytes}, init, vary, serialize, sink_of, num_packets) do
    {best_write, best_read, sink} =
      Enum.reduce(0..@num_trials, {nil, nil, 0}, fn trial, {bw, br, sink} ->
        t0 = System.monotonic_time(:nanosecond)
        sink_w = shape_write_loop(num_packets, lcg_seed(), init, vary, serialize, 0)
        write_ns = System.monotonic_time(:nanosecond) - t0

        t0 = System.monotonic_time(:nanosecond)
        sink_r = shape_read_loop(num_packets, 0, variants, init, serialize, sink_of, 0)
        read_ns = System.monotonic_time(:nanosecond) - t0

        sink = sink + sink_w + sink_r

        if trial == 0 do
          {bw, br, sink}
        else
          {best_of(bw, write_ns), best_of(br, read_ns), sink}
        end
      end)

    packets = num_packets / 1_000_000
    write_mpps = packets / (best_write * 1.0e-9)
    read_mpps = packets / (best_read * 1.0e-9)

    {[
       {row, "write", "Mpackets/s", write_mpps},
       {row, "read", "Mpackets/s", read_mpps}
     ],
     [
       "#{label}  write: #{pad(fmt(write_mpps, 1), 6)} M packets/s   read: #{pad(fmt(read_mpps, 1), 6)} M packets/s\n"
     ], sink}
  end

  # ------------------------------------------------------------------
  # main
  # ------------------------------------------------------------------

  def main(argv) do
    csv = "--csv" in argv
    passes = env_int("BENCH_BITPACKER_PASSES", 4096)
    num_packets = env_int("BENCH_STREAM_PACKETS", 1_000_000)

    # every row's golden gate runs before any row is timed: a bench that
    # fails its goldens reports nothing at all
    bitpacker_data = gate_bitpacker()
    gated_stream = gate_stream()

    gated_int =
      gate_shape(
        "int_packet",
        init_int_fields(),
        &vary_int_fields/2,
        &serialize_int_fields/2,
        @pin_int
      )

    gated_bits =
      gate_shape(
        "bits_packet",
        init_bits_fields(),
        &vary_bits_fields/2,
        &serialize_bits_fields/2,
        @pin_bits
      )

    gated_gen =
      gate_shape(
        "mixed_packet",
        init_gen_fields(),
        &vary_gen_fields/2,
        &serialize_gen_fields/2,
        @pin_gen
      )

    otp = :erlang.system_info(:otp_release) |> List.to_string()
    erts = :erlang.system_info(:version) |> List.to_string()

    header =
      "\n[serialize.elixir benchmark]\n" <>
        "Erlang/OTP #{otp} (erts-#{erts}, BeamAsm) / Elixir #{System.version()}\n" <>
        "one untimed pass per leg, then best of #{@num_trials} trials\n\n"

    unless csv, do: IO.write(header)

    {rows1, lines1, sink1} = bench_bitpacker(bitpacker_data, passes)
    unless csv, do: IO.write(Enum.join(lines1))

    {rows2, lines2, sink2} = bench_stream(gated_stream, num_packets)
    unless csv, do: IO.write(Enum.join(lines2) <> "\n")

    {rows3, lines3, sink3} =
      bench_shape(
        "int_packet",
        "int packet   (runtime):     ",
        gated_int,
        init_int_fields(),
        &vary_int_fields/2,
        &serialize_int_fields/2,
        & &1.f0,
        num_packets
      )

    unless csv, do: IO.write(Enum.join(lines3))

    {rows4, lines4, sink4} =
      bench_shape(
        "bits_packet",
        "bits packet  (runtime):     ",
        gated_bits,
        init_bits_fields(),
        &vary_bits_fields/2,
        &serialize_bits_fields/2,
        & &1.b7,
        num_packets
      )

    unless csv, do: IO.write(Enum.join(lines4))

    {rows5, lines5, sink5} =
      bench_shape(
        "mixed_packet",
        "mixed packet (runtime):     ",
        gated_gen,
        init_gen_fields(),
        &vary_gen_fields/2,
        &serialize_gen_fields/2,
        & &1.sequence,
        num_packets
      )

    unless csv, do: IO.write(Enum.join(lines5))

    unless csv do
      IO.write(
        "\n(the C++ bench also prints a compile time row per shape. that surface is\n" <>
          " C++ template machinery with no counterpart here, the same omission the\n" <>
          " C bench makes.)\n\n"
      )
    end

    if csv do
      rows = rows1 ++ rows2 ++ rows3 ++ rows4 ++ rows5

      IO.write(
        "row,op,units,value\n" <>
          Enum.map_join(rows, fn {row, op, units, value} ->
            "#{row},#{op},#{units},#{fmt(value, 4)}\n"
          end)
      )
    end

    # the g_sink escape: the loops' work is observable after the run
    :persistent_term.put(:serialize_bench_sink, sink1 + sink2 + sink3 + sink4 + sink5)
  end
end

Bench.main(System.argv())
