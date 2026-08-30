# serialize.elixir

A bitpacking serialization library for **Elixir** on the BEAM. Part of
the serialize family, wire compatible with the
[C++](https://github.com/mas-bandwidth/serialize),
[C](https://github.com/mas-bandwidth/serialize.c),
[Go](https://github.com/mas-bandwidth/serialize.go),
[C#](https://github.com/mas-bandwidth/serialize.cs),
[Rust](https://github.com/mas-bandwidth/serialize.rs),
[JavaScript](https://github.com/mas-bandwidth/serialize.js),
[Dart](https://github.com/mas-bandwidth/serialize.dart) and
[Java](https://github.com/mas-bandwidth/serialize.java) libraries — the
same values produce the same bytes in every implementation, so a stream
written by one reads in any other.
[STANDARD.md](https://github.com/mas-bandwidth/serialize/blob/main/STANDARD.md)
in the C++ reference is the authority on every byte.

## The surface

The complete family operation set in the `Serialize` module, unified
over three immutable streams — `Serialize.WriteStream`,
`Serialize.ReadStream` and `Serialize.MeasureStream` — so one serialize
function per message covers writing, reading and measuring. Every
operation returns `{:ok, stream, value}` or `{:error, stream}`; writer
contract violations raise `ArgumentError`; hostile bytes refuse as
values and never raise. [USAGE.md](USAGE.md) teaches every operation by
example.

- **Raw bits**: `serialize_bits/3` (1–64 bits in one call — BEAM
  integers are arbitrary precision), `serialize_align/1`.
- **Ranged integers**: `serialize_int/4`, `serialize_int64/4`,
  `serialize_int128/4` — offset from min in exactly the bit length of
  the range, zero bits for a degenerate range.
- **Unsigned helpers and bool**: `serialize_uint8` / `16` / `32` / `64`,
  `serialize_uint128`, `serialize_bool/2`.
- **Floats**: `serialize_float/2` and `serialize_double/2`, bit
  transparent both ways — non-finite patterns travel as
  `{:nonfinite, bits}`, because BEAM float terms cannot be NaN or
  infinity; `serialize_compressed_float/5`, quantizing in float32 with
  the standard's two roundings on each side, emulated exactly.
- **Bytes and strings**: `serialize_bytes/3` (aligned bulk copy, count
  agreed, not transmitted); `serialize_string/3` (UTF-8 on the wire,
  payload validated on read); `serialize_wstring/3` (one 32-bit group
  per UTF-16 code unit, no alignment anywhere).
- **The relative integer**: `serialize_int_relative/3` — the flag ladder
  for strictly increasing uint32 sequences, one bit for a difference
  of 1.
- **Fixed point**: `serialize_fixed/6` — Q formats at 8/16/32/64/128-bit
  storage in one function, the raw scaled integer as an exact ranged
  offset, byte identical to `serialize_int64` wherever storage fits 64
  bits.
- **Range pricing**: `Serialize.Bits.bits_required/2` — one function
  covers the 32, 64 and 128 bit domains.
- **The bitpacker underneath**: `Serialize.BitWriter` and
  `Serialize.BitReader`, the family wire on BEAM binaries.

Zero external dependencies.

## Quick example

One serialize function per message covers writing, reading and measuring —
the family's unified pattern, composed with `with`:

```elixir
alias Serialize.{ReadStream, WriteStream}

def serialize(stream, d) do
  with {:ok, stream, x} <- Serialize.serialize_int(stream, d.x, -100, 100),
       {:ok, stream, flag} <- Serialize.serialize_bool(stream, d.flag) do
    {:ok, stream, %{d | x: x, flag: flag}}
  end
end

# write
{:ok, writer, _} = serialize(WriteStream.new(), %{x: -37, flag: true})
data = writer |> WriteStream.flush() |> WriteStream.data()

# read: hostile bytes refuse as {:error, stream}, never raise
{:ok, _reader, decoded} = serialize(ReadStream.new(data), %{x: 0, flag: false})
```

Writes assume trusted data — caller contract violations raise
`ArgumentError`. Reads validate always.

## Toolchain

The toolchain is pinned per project, never system-wide:
[tending/PINS.md](tending/PINS.md) records the exact OTP and Elixir
versions, download URLs and SHA-256 hashes. `dist/` is gitignored —
re-fetch by the pinned URLs, verify the hashes, unpack, and prefix the
PATH:

```sh
export PATH="$PWD/dist/otp-29.0.5/bin:$PWD/dist/elixir-1.20.4/bin:$PATH"
```

## Testing

```sh
mix test
```

ExUnit alone, no test dependencies. The suite pins the family's golden
vectors byte for byte — the golden wire message covering every operation
class, the discriminating compressed-float vectors (bit patterns, not
tolerances), the string and wide-string pins, every relative-integer
tier, and the fixed point shapes at every group count — plus
per-primitive unit suites, refusal proofs for hostile input, and the
measure bound.

## Benchmark

The family benchmark, mirrored operation for operation from the C bench and
golden gated against the C reference pins — it verifies its wire byte for
byte before timing anything, and reports nothing on a failed gate:

```sh
mix run bench/bench.exs           # the rows, human readable
mix run bench/bench.exs --csv     # the same numbers as CSV
```

Iteration counts are env-overridable (`BENCH_BITPACKER_PASSES`,
`BENCH_STREAM_PACKETS`) for linearity checks at other scales.

Current numbers at the family scale (4096 bitpacker passes, 1,000,000
packets per stream row), measured on a MacBook Air (Apple Silicon) —
only numbers from a quiet machine are meaningful, and only as ratios
between family legs measured back to back on the same machine:

```
bitpacker write:      48.4 MB/s
bitpacker read:       61.7 MB/s
stream write:         42.2 MB/s  (0.9 M packets/s)
stream read:          71.8 MB/s  (1.5 M packets/s)
stream measure:                   2.0 M packets/s

int packet   (runtime):       write:    1.3 M packets/s   read:    1.9 M packets/s
bits packet  (runtime):       write:    1.5 M packets/s   read:    2.7 M packets/s
mixed packet (runtime):       write:    1.1 M packets/s   read:    1.8 M packets/s
```

Two costs are structural and deliberately left visible rather than
benched around: streams are immutable, so every packet constructs a
fresh stream and every operation returns a new one, and the decoded
packet is rebuilt as a new map per packet — the library's own surface,
measured as shipped. Writes always validate their caller contract (the
library has no separate release shape), so the checked variant is the
only variant, and the numbers are the numbers a user gets.

## Write stream growth

The write stream grows without bound and takes no capacity: the runtime
appends through ERTS append-optimized binaries (reserved space doubles as
writes land, amortized O(1)), and Erlang exposes no way to pre-size a
binary's reservation — so a capacity parameter here would be accepted and
ignored. Sizing a buffer up front is the other ports' surface, where
buffers are real.

## License

[BSD 3-Clause](LICENSE), © Más Bandwidth LLC.
