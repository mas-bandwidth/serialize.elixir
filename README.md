# serialize.elixir

Bitpacked binary serialization for Elixir on the BEAM: the serialize wire
format, byte-identical to the C, C++, C#, Go, Rust, JavaScript, Dart and Java
implementations. STANDARD.md in the reference repository is the authority on
every byte.

## Toolchain

Pinned per project, never system-wide:

```sh
export PATH="$PWD/dist/otp-29.0.5/bin:$PWD/dist/elixir-1.20.4/bin:$PATH"
```

Zero external dependencies: `mix test` runs the full battery with ExUnit
alone.

## Usage

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
`ArgumentError`. Reads validate always. Non-finite IEEE-754 patterns travel
through the bit-transparent `serialize_float`/`serialize_double` as
`{:nonfinite, bits}`, since the BEAM has no non-finite float terms.
