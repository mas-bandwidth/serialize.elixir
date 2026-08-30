# Using serialize.elixir

Everything the library does, by example. The wire format itself is
defined by the C++ reference's
[STANDARD.md](https://github.com/mas-bandwidth/serialize/blob/main/STANDARD.md);
this document teaches the Elixir surface that speaks it.

```elixir
alias Serialize.{MeasureStream, ReadStream, WriteStream}
```

## One serialize function, three streams

The family's defining pattern: write, read and measure share a single
serialize function. Streams are immutable — every operation returns

- `{:ok, stream, value}` — the advanced stream, and the value written
  (echoed) or read (decoded);
- `{:ok, stream}` — for `serialize_align/1`;
- `{:error, stream}` — a read refusal, the reference's `false` return.

so a message composes as a `with` chain, and the stream direction
decides whether the value argument is consumed or ignored:

```elixir
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

# measure
{:ok, measure, _} = serialize(MeasureStream.new(), %{x: -37, flag: true})
Serialize.bits_processed(measure) # 9
```

On a write or measure stream the value arguments are the message; on a
read stream they are ignored and the decoded values come back in the
`{:ok, stream, value}` tuples — which is why one function serves all
three directions. The reference's `serialize_object` is composition,
contributes no bytes, and needs no operation here: compose with plain
function calls.

`WriteStream.new/0` takes no capacity — the stream grows without bound
(see the README's "Write stream growth"). Always pipe through
`WriteStream.flush/1` before `WriteStream.data/1`. `ReadStream.new/1`
takes the bytes; any length is supported and nothing past the data is
read. `MeasureStream.new/0` touches no memory at all — it prices a
message; its bound is conservative (see [Measuring](#measuring)).

All three streams answer `Serialize.bits_processed/1`,
`Serialize.bytes_processed/1` and `Serialize.align_bits/1`.

## Writes trust, reads validate

The check model is the family standard's ("Writes assume trusted data"):
**the caller is responsible for well-formed writes**, and reads validate
everything, because the wire is a trust boundary.

On the read side, every failure — a truncated read, a value outside its
range, nonzero alignment padding, a malformed string — refuses as
`{:error, stream}`, and hostile bytes never raise. A refusal is terminal
for the stream: nothing after the failing operation has a defined
position.

```elixir
reader = ReadStream.new(<<0x00>>)              # 8 bits of data
Serialize.serialize_bits(reader, 0, 32)        # {:error, stream}: past the end

# an offset smuggled into the bit headroom of a range is refused
reader2 = ReadStream.new(<<0xFF>>)
Serialize.serialize_int(reader2, 0, 0, 200)    # {:error, stream}: 8 bits carry 255
```

On the write and measure sides, caller contract violations — a value
outside its declared range, a non-boolean where a boolean is due, an
invalid declaration, a string that does not fit — raise `ArgumentError`,
this implementation's misuse convention. The contracts are always on:
raising is idiomatic BEAM error handling for broken code, and pattern
matching and guards do most of the checking for free, so the library has
no separate release shape. Misuse raises at the call site; it never
reaches the wire.

```elixir
Serialize.serialize_int(WriteStream.new(), 999, 0, 100)
# ** (ArgumentError) serialize_int value 999 outside [0, 100]
```

One rule follows from clean refusal: check the result of any serialized
value that controls a loop before the loop uses it, or a truncated
packet spins the loop on garbage — the `with` chain does this naturally.

## Raw bits

`serialize_bits/3` moves the low `bits` of an unsigned value, 1 to 64
bits in one call — BEAM integers are arbitrary precision, so there is no
separate 64-bit entry point. Values wider than 32 bits go low 32-bit
group first — the family's group rule.

```elixir
stream = WriteStream.new()
{:ok, stream, _} = Serialize.serialize_bits(stream, 5, 3)                   # 3 bits on the wire
{:ok, stream, _} = Serialize.serialize_bits(stream, 0xDEADBEEF, 32)         # full width
{:ok, stream, _} = Serialize.serialize_bits(stream, 0x123456789ABCDEF0, 64) # low group first
{:ok, stream} = Serialize.serialize_align(stream)                           # zero-pads to the byte boundary
```

`serialize_align/1` writes zero bits up to the next byte boundary
(nothing if already aligned); the reader verifies the padding is zero
and refuses otherwise.

## Ranged integers

`serialize_int/4` is the format's defining operation: the value rides as
an offset from `min` in exactly `Serialize.Bits.bits_required(min, max)`
bits. Both sides must state the same range — the range is part of the
message format, not the wire.

```elixir
{:ok, stream, _} = Serialize.serialize_int(stream, -37, -100, 100)  # 8 bits
{:ok, stream, _} = Serialize.serialize_int(stream, 7, 7, 7)         # degenerate range: ZERO bits
```

Reads refuse values smuggled into the bit headroom of a range (an offset
above `max - min` fails the read — reject, never clamp).

`serialize_int64/4` and `serialize_int128/4` are the same operation with
64-bit and 128-bit bounds — arbitrary precision integers make the
arithmetic exact at any width, and the wire is written in 32-bit groups
least significant first. Where a 128-bit range fits 64 bits the bytes
are identical to `serialize_int64/4`. The 128-bit bounds must satisfy
`min < max` strictly, as the reference asserts at this width.

```elixir
{:ok, stream, _} =
  Serialize.serialize_int64(stream, -5_000_000_000, -5_000_000_000, 5_000_000_000)  # 34 bits

{:ok, stream, _} =
  Serialize.serialize_int128(stream, -1, -0x80000000000000000000000000000000, 0x7FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF)  # 128 bits
```

`Serialize.Bits.bits_required/2` prices a range when designing a message
format — one function covers the 32, 64 and 128 bit domains, on
non-negative (unsigned-domain) bounds:

```elixir
Serialize.Bits.bits_required(0, 200)                # 8: the cost of serialize_int over [-100, +100]
Serialize.Bits.bits_required(0, 5_000_000_000)      # 33
Serialize.Bits.bits_required(0, Bitwise.bsl(1, 100)) # 101
```

## The unsigned helpers and bool

Fixed-width conveniences over `serialize_bits`: always 8/16/32/64/128
bits. `serialize_uint128/2` writes the low 64-bit half first, then the
high half. `serialize_bool/2` is one bit.

```elixir
{:ok, stream, _} = Serialize.serialize_uint8(stream, 0x7F)
{:ok, stream, _} = Serialize.serialize_uint16(stream, 0x1234)
{:ok, stream, _} = Serialize.serialize_uint32(stream, 0x12345678)
{:ok, stream, _} = Serialize.serialize_uint64(stream, 0xFEDCBA9876543210)
{:ok, stream, _} = Serialize.serialize_uint128(stream, Bitwise.bsl(1, 100) + 1)
{:ok, stream, _} = Serialize.serialize_bool(stream, true)
```

Values are plain non-negative integers at every width — no pair types,
no bit-transparent signed carriers: arbitrary precision integers hold
the full unsigned 128-bit domain directly.

## Floats and doubles: bit transparent

`serialize_float/2` (32 bits) and `serialize_double/2` (64 bits)
reproduce the transmitted pattern exactly — every pattern is legal on
the wire: NaNs with any payload, signaling NaNs, infinities, negative
zero, denormals.

```elixir
{:ok, stream, _} = Serialize.serialize_float(stream, Serialize.Float32.round32(3.1415926))
{:ok, stream, _} = Serialize.serialize_double(stream, 1.0 / 3.0)
```

A float is 32 bits on the wire: write values rounded through
`Serialize.Float32.round32/1` or the read-back differs from what you
wrote.

**Non-finite patterns travel as `{:nonfinite, bits}`** — BEAM float
terms cannot be NaN or infinity, so the exact IEEE-754 pattern rides in
a tagged integer instead, and the wire stays bit transparent:

```elixir
{:ok, stream, _} = Serialize.serialize_float(stream, {:nonfinite, 0x7F800001})   # a signaling NaN
{:ok, stream, _} = Serialize.serialize_double(stream, {:nonfinite, 0xFFF0000000000000}) # -Inf

# the read side hands the same tagged pattern back, bit for bit
{:ok, _reader, {:nonfinite, 0x7F800001}} = Serialize.serialize_float(reader, 0.0)
```

`Serialize.Float32` carries the pattern helpers: `bits32/1` / `value32/1`,
`bits64/1` / `value64/1`, `finite32?/1` / `finite64?/1`, and `round32/1`
— the float32 rounding boundary the compressed float arithmetic is
pinned to.

## The compressed float

`serialize_compressed_float/5` quantizes into a declared range at a
resolution — the one lossy operation. The declaration is part of the
message format. The arithmetic is float32 with the standard's two
roundings on each side, emulated exactly on the BEAM's doubles, and the
family's discriminating vectors pin the decoded bit patterns.

```elixir
{:ok, stream, _} = Serialize.serialize_compressed_float(stream, 5.0, 0.0, 10.0, 0.01) # 10 bits
# reading it back yields exactly 5.0: the value sits on a quantum.
# off-quantum values come back within the resolution; re-encoding a
# decoded value is byte-identical (the round trip is idempotent).
```

Finite values outside `[min, max]` clamp on write; a non-finite value or
declaration raises `ArgumentError` (writer contract); reads refuse
integers smuggled above the quantization ceiling.

## Raw bytes

`serialize_bytes/3` aligns to the byte boundary (the alignment is part
of the format, padding verified on read) and then bulk-copies `count`
bytes. The count is never transmitted: both sides agree on it. On read,
the data argument is ignored and the bytes come back as a sub-binary of
the stream's data — no copy.

```elixir
{:ok, stream, _} = Serialize.serialize_bytes(stream, <<0xDE, 0xAD, 0xBE, 0xEF>>, 4)
# ...
{:ok, reader, payload} = Serialize.serialize_bytes(reader, nil, 4)
# payload == <<0xDE, 0xAD, 0xBE, 0xEF>>
```

A zero-count call still performs (and verifies) the align.

## Strings: UTF-8 on the wire

`serialize_string/3` sends the UTF-8 byte length as
`serialize_int(length, 0, buffer_size - 1)`, then the payload via the
aligning bytes operation. `buffer_size` is part of the message format —
the same string against different buffer sizes produces different bytes
— and the payload must fit `buffer_size - 1` bytes. An Elixir string is
already UTF-8, so the payload is the binary itself.

```elixir
{:ok, stream, _} = Serialize.serialize_string(stream, "golden", 16)
# ...
{:ok, reader, "golden"} = Serialize.serialize_string(reader, nil, 16)
```

Reads validate the payload in every case: malformed UTF-8 and interior
NULs refuse as `{:error, stream}` — an interior NUL is the classic
two-lengths smuggling primitive. On write, the payload is well-formed
UTF-8 with no interior NUL by writer contract (unchecked, per the
trusted-writes doctrine); a value that is not a binary, or does not fit
`buffer_size`, raises `ArgumentError`.

## Wide strings: UTF-16 code units

`serialize_wstring/3` sends the unit count, then one 32-bit group per
UTF-16 code unit — never a code point — with no alignment anywhere: the
one place the wide path deliberately differs from its narrow
counterpart. An astral code point travels as its surrogate pair, exactly
as the family's 2-byte-wchar_t ports split it, and the pair recombines
into the code point on read. `buffer_size` counts wide characters.

```elixir
{:ok, stream, _} = Serialize.serialize_wstring(stream, "😀A", 8)  # 3 code units: 99 bits
# ...
{:ok, reader, "😀A"} = Serialize.serialize_wstring(reader, nil, 8)
```

Reads refuse groups above 0xFFFF, interior NUL groups, and unpaired,
misordered or dangling surrogates.

## The relative integer

`serialize_int_relative/3` prices strictly increasing unsigned 32-bit
sequences — sequence numbers, ack chains. `current > previous` always,
no wrapping. A difference of 1 costs a single bit; small differences
ride payload tiers of 5/8/13/18/23 bits; past the ladder, six zero flags
carry `current` itself as 32 raw bits, and the reader enforces the
ordering on that absolute form too.

```elixir
{:ok, stream, _} = Serialize.serialize_int_relative(stream, 100, 101)   # 1 bit
{:ok, stream, _} = Serialize.serialize_int_relative(stream, 100, 2100)  # a mid-ladder tier
# read side: pass the same previous, get current back
{:ok, reader, 101} = Serialize.serialize_int_relative(reader, 100, 0)
```

`previous` is caller state, not wire: both sides already know it.
Writing `current <= previous` raises `ArgumentError`.

## Fixed point

`serialize_fixed/6` carries Q-format fixed point. `value` is the **raw
scaled integer** — the real value times `2^fraction_bits` — with storage
of exactly `integer_bits + fraction_bits` bits (8, 16, 32, 64 or 128 in
this one function — arbitrary precision integers need no separate wide
entry point; the sign bit counts toward `integer_bits`). `min` and `max`
are in **whole units**, part of the message format.

```elixir
# -3.25 in Q8.8 over [-100, +100] whole units: raw is -3.25 * 256 = -832
{:ok, stream, _} = Serialize.serialize_fixed(stream, -832, 8, 8, -100, 100)  # 16 bits

# 1234.5 in Q16.16 over [-2000, +2000]
{:ok, stream, _} = Serialize.serialize_fixed(stream, 1234 * 65536 + 32768, 16, 16, -2000, 2000)

# 12345.5 in Q48.16 over [-100000, +100000]: 64-bit storage
{:ok, stream, _} = Serialize.serialize_fixed(stream, 12345 * 65536 + 32768, 48, 16, -100_000, 100_000)  # 34 bits

# 1.0 in Q64.64 over [-1000, +1000] whole units: 128-bit storage
{:ok, stream, _} = Serialize.serialize_fixed(stream, Bitwise.bsl(1, 64), 64, 64, -1000, 1000)
```

The wire is the offset from `min <<< fraction_bits` in exactly the bit
length of the raw range, split into 32-bit groups from least significant
upward — byte identical to `serialize_int64` of the raw value wherever
storage fits 64 bits — and the round trip is **exact**: no quantization,
unlike the compressed float. A degenerate `min == max` range costs zero
bits on every storage width. Reads refuse raw values smuggled into the
bit headroom; an invalid declaration raises `ArgumentError`.

## Measuring

`Serialize.MeasureStream` prices a message without touching memory. For
everything except alignment it is exact; any operation that aligns
(`serialize_align`, `serialize_bytes`, `serialize_string`) charges the
worst case — 7 bits of padding — because the measure stream cannot know
what alignment the field will land on inside your message. The guarantee
is a bound, never equality:

```elixir
Serialize.bits_processed(measure) >= Serialize.bits_processed(writer) # always true
```

## The bitpacker underneath

`Serialize.BitWriter` and `Serialize.BitReader` are the streams' engine
— the family wire on BEAM binaries — for code that wants raw bitpacking
without the serialize surface or its checks:

```elixir
writer =
  BitWriter.new()
  |> BitWriter.write_bits(5, 3)
  |> BitWriter.write_align()
  |> BitWriter.write_bytes(<<1, 2, 3>>)
  |> BitWriter.flush()

reader = BitReader.new(BitWriter.data(writer))
{5, reader} = BitReader.read_bits(reader, 3)
{:ok, reader} = BitReader.read_align(reader)       # padding was zero
{<<1, 2, 3>>, _reader} = BitReader.read_bytes(reader, 3)
```

Any data length is supported and nothing past the data is read.

## Wire compatibility

The same values produce the same bytes in every family implementation.
This is not aspiration but pinned fact: the test suite carries the
family's golden vectors — including the golden wire message covering
every operation class, byte for byte — plus the discriminating float
vectors, the string and wide-string pins, every relative-integer tier,
and the fixed point shapes at every group count, all minted from the
canonical C++ reference's own output. If your message serializes with
the same declarations on both ends, a stream written by any family
implementation reads in any other.

Two doctrines worth knowing at the edges:

- **Trailing bits**: writers zero the unused bits of the final byte;
  readers never reject a stream for their contents.
- **Past-end data**: bytes past the end of the data you hand
  `ReadStream.new/1` are never read, let alone interpreted.
