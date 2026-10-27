# serialize.elixir

![serialize.elixir logo with a packed row of colored blocks](images/serialize.png)

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
[STANDARD.md](STANDARD.md) is the authority on every byte — a verbatim
copy of the specification in
[mas-bandwidth/serialize](https://github.com/mas-bandwidth/serialize),
vendored here beside the implementation and held to the upstream text by
a CI check. serialize.elixir 2.x implements **format version 2.0**.

If this library helps you, **[please support it](https://www.patreon.com/MasBandwidth/membership)**

## Getting it

serialize.elixir ships as source today. The implementation is ready and the
package is not yet published: `mix.exs` declares the app `:serialize` and
carries no Hex package metadata, and nothing named `serialize` exists on
hex.pm. Publishing it there is a separate round.

Depend on it from git:

```elixir
defp deps do
  [
    {:serialize, git: "https://github.com/mas-bandwidth/serialize.elixir.git", tag: "v2.0.1"}
  ]
end
```

`mix deps.get`, and the modules are yours:

```elixir
alias Serialize.{MeasureStream, ReadStream, WriteStream}
```

Pure Elixir on the BEAM, zero dependencies. Pin a release tag as above rather
than tracking `main`. The newest is on the
[releases page](https://github.com/mas-bandwidth/serialize.elixir/releases): a
release states a format version, and two endpoints interoperate only when they
carry the same one.

## The surface

The complete family operation set in the `Serialize` module, unified
over three immutable streams — `Serialize.WriteStream`,
`Serialize.ReadStream` and `Serialize.MeasureStream` — so one serialize
function per message covers writing, reading and measuring. Every
operation returns `{:ok, stream, value}` or `{:error, stream}`; writer
contract violations raise `ArgumentError`; hostile bytes refuse as
values and never raise. A refusal is terminal — the read stream latches
failed, and every later read on it refuses — and hands back no value at
all. Every refusal names its rule from the standard's closed list
(`:past_end`, `:value_out_of_range`, `:nonzero_padding`, `:trailing_data`,
`:non_finite_float`, `:invalid_utf8`, `:embedded_nul`, `:non_canonical`),
and `Serialize.refusal/1` reads the first one. [USAGE.md](USAGE.md)
teaches every operation by example.

- **Raw bits**: `serialize_bits/3` (1–64 bits in one call — BEAM
  integers are arbitrary precision), `serialize_align/1`.
- **Ranged integers**: `serialize_int/4`, `serialize_int64/4`,
  `serialize_int128/4` — offset from min in exactly the bit length of
  the range. `min <= max` is the legal relation at every width, and a
  degenerate `min == max` range costs zero bits.
- **Unsigned helpers and bool**: `serialize_uint8` / `16` / `32` / `64`,
  `serialize_uint128`, `serialize_bool/2`.
- **Floats**: `serialize_float/2` and `serialize_double/2`, finite
  values only and every one bit exact, -0.0 and the subnormals included;
  a reader refuses NaN and the infinities as `:non_finite_float`.
  `serialize_compressed_float/5`, quantizing in float32 with the
  standard's two roundings on each side, emulated exactly, and refusing a
  decode that is not finite.
- **Bytes and strings**: `serialize_bytes/3` (aligned bulk copy, count
  agreed, not transmitted); `serialize_string/3` (UTF-8 on the wire,
  payload validated on read, handed back byte for byte).
- **The relative integer**: `serialize_int_relative/3` — the flag ladder
  for strictly increasing sequences over the domain `0` to `2^31 - 1`,
  one bit for a difference of 1, and one encoding per value.
- **The end**: `serialize_end/1` — a packet reader calls it after the
  last field of the top-level object, and it refuses trailing bytes and
  set padding, so one value is always one byte sequence.
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
       {:ok, stream, flag} <- Serialize.serialize_bool(stream, d.flag),
       # the packet ends here, and so must the stream
       {:ok, stream} <- Serialize.serialize_end(stream) do
    {:ok, stream, %{d | x: x, flag: flag}}
  end
end

# write
{:ok, writer, _} = serialize(WriteStream.new(), %{x: -37, flag: true})
data = writer |> WriteStream.flush() |> WriteStream.data()

# read: hostile bytes refuse as {:error, stream}, never raise
{:ok, _reader, decoded} = serialize(ReadStream.new(data), %{x: 0, flag: false})

# a byte more is trailing data, and the refusal says so
{:error, reader} = serialize(ReadStream.new(data <> <<0>>), %{x: 0, flag: false})
:trailing_data = Serialize.refusal(reader)
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
mix test --only controls
```

ExUnit alone, no test dependencies. The suite runs the family's shared
conformance corpus, vendored verbatim in [conformance/](conformance) and
held to upstream by a CI check. The suite discovers that directory rather
than naming its files, so a newly vendored file runs without anyone
editing a list, an empty directory fails the run, and a vector whose
operation the runner cannot drive fails rather than being skipped. Every
vector goes through this port's reader: an accepted vector must yield its
value and consume exactly the stated bits, a vector marked `writer =
canonical` must round trip back through the write stream byte for byte,
a vector carrying `writer_input` must make the writer emit its bytes, a
sequence stating `measure_at_least` must measure at least its floor, and
a refused vector must refuse for its stated reason, hand back no value,
poison every later step and leave the stream terminal with its first
reason. Beside it the suite pins the family's golden vectors byte for
byte — the golden wire message covering every operation class, the
discriminating compressed-float vectors (bit patterns, not tolerances),
the string pins, every relative-integer tier, and the fixed point shapes
at every group count — plus per-primitive unit suites, refusal proofs
for hostile input, terminal failure after every class of refusal, and
the measure bound.

`mix test --only controls` runs the negative controls, vendored with the
corpus in [conformance-controls/](conformance-controls): a vector whose
operation has no runner must go red, and for each refusal rule a reader
with that one rule deleted, compiled into the VM from a patched copy of
the source, must fail exactly the vectors the rule's `.expected` list
names. The surrogate clause of the UTF-8 rule is adapted: this port
validates with `String.valid?/1`, which has no clause to delete, so its
sabotage masks every encoded surrogate before validating.

[`interop/`](interop) takes it further: the CI `interop` job builds the
C++ reference at a pinned release and runs it head to head with this
port. Both halves write the same boundary message — every operation the
standard defines, at its boundary values — and the files must be byte
identical; each then decodes the other's bytes and re-encodes them
exactly; both must refuse every truncation of the other's stream, and the
stream one byte longer; and both run the corpus. The release candidate in this repository exchanges
bytes with the reference on every push, so wire compatibility is
measured rather than asserted. `mix run interop/interop.exs write
out.bin` runs one exchange by hand.

`mix dialyzer` (dialyxir, pinned, dev only) holds every `@spec` and
`@type` in `lib/` against the success typing of the code, with zero
warnings and no ignore file. The CI `dialyzer` job runs it, then plants
one type violation and requires dialyzer to refuse it.

[`fuzz/`](fuzz) is the differential fuzzer, the family's pattern for a
language with no native coverage-guided fuzzer: a Go module pinning
serialize.go v2 as the other side generates programs over every
operation, ended by `serialize_end`, and runs them through
`fuzz/driver.exs` a batch per BEAM start. Both writers must emit
identical bytes, each side must read the other's bytes back to the values
written, the measure must never under-measure, and on mutated and hostile
bytes both readers must agree on whether, where and why they stop. CI runs
a sixty second smoke run on a fixed seed and requires the `-widen-int`
negative control to go red; `nightly-fuzz.yml` runs an hour on a fresh,
logged seed and uploads failing programs, replayable by the driver.

```sh
MIX_ENV=test mix compile
cd fuzz && go test -count=1 -run TestDifferentialAgainstSerializeGo -v . -duration 60s
```

Benchmarking for the serialize family lives in [mas-bandwidth/schema](https://github.com/mas-bandwidth/schema)'s data-driven bench, which measures the generated codecs across every language on one corpus.

## Write stream growth

The write stream grows without bound and takes no capacity: the runtime
appends through ERTS append-optimized binaries (reserved space doubles as
writes land, amortized O(1)), and Erlang exposes no way to pre-size a
binary's reservation — so a capacity parameter here would be accepted and
ignored. Sizing a buffer up front is the other ports' surface, where
buffers are real.

## License

[BSD 3-Clause](LICENSE), © Más Bandwidth LLC.
