defmodule Serialize.ConformanceRunner do
  @moduledoc """
  The runner for the shared conformance corpus: one vector through this
  port's reader, writer and measure, with the obligations STANDARD.md "What
  a runner checks" states. `Serialize.ConformanceTest` runs every vector in
  `conformance/` through it, and `Serialize.ControlsTest` runs the same
  corpus through it against sabotaged readers, which must fail exactly the
  vectors `conformance-controls/<rule>.expected` names.

  A disagreement with the corpus raises `ExUnit.AssertionError`; nothing is
  ever skipped. The expectations come from the corpus, never from this port.
  """

  import ExUnit.Assertions

  alias Serialize.{ConformanceVectors, Float32, MeasureStream, ReadStream, WriteStream}

  # The buffer contract, STANDARD.md "The conformance corpus": every stream
  # is presented with the slack its port's contract requires, filled with a non-zero pattern so a decode that depends on
  # memory past the end cannot pass by reading zeros. This port's streams
  # are BEAM binaries whose length is the stream's length, so the slack it
  # requires of a caller is zero bytes -- and to make the requirement
  # measurable rather than assumed, each stream below is a sub-binary of a
  # larger buffer whose trailing bytes are 0xA5, including the empty stream
  # of a zero-bit read.
  @slack 8
  @slack_fill 0xA5

  # The destination a refused read must leave alone. This port returns the
  # decoded value rather than writing through a caller's reference, so the
  # sentinel goes IN as the value argument and the check is on the way out:
  # a refusal must return no value at all.
  @sentinel :destination_sentinel

  # A step that produces no value of its own -- `align` and `end`, which the
  # corpus renders as the padding a conforming read always finds, and
  # `object`, which contributes nothing.
  @no_value :no_value_of_its_own

  @mask128 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF

  # Which operation takes which parameter. A parameter this runner does not
  # understand is a FAILURE and not a silent default: a vector whose
  # declaration is not the one being exercised proves nothing.
  @params_by_operation %{
    "preceding_bits" => ["align", "bytes"],
    "bits" => ["bits"],
    "count" => ["bytes"],
    "buffer_size" => ["string"],
    "previous" => ["int_relative"],
    "res" => ["compressed_float"],
    "integer_bits" => ["fixed"],
    "fraction_bits" => ["fixed"],
    "min" => ["int", "int64", "int128", "fixed", "compressed_float"],
    "max" => ["int", "int64", "int128", "fixed", "compressed_float"]
  }

  # The value of each step kind is either a bit pattern or a number, and both
  # compare as 128-bit two's complement patterns. Never through a float: NaN
  # compares unequal to itself, -0.0 == 0.0, and no tolerance comparison can
  # see a quieted signaling bit.
  @pattern_kinds [:bits, :uint128, :float, :double, :compressed_float]
  @number_kinds [:int, :int64, :int128, :int_relative, :fixed]

  # ------------------------------------------------------------------
  # one vector
  # ------------------------------------------------------------------

  @doc """
  Runs one vector through this port's reader, and its writer and measure
  where the record asks for them. Returns `:ok`, and raises
  `ExUnit.AssertionError` on any disagreement with the corpus.
  """
  @spec run_vector(ConformanceVectors.t()) :: :ok
  def run_vector(vector) do
    check_params!(vector)
    nodes = build_nodes(vector)
    if vector.writer_input, do: run_writer_input(vector, nodes)

    case run_reader(vector, nodes) do
      {:refused, _stream} ->
        :ok

      {:accepted, reader, nodes} ->
        if vector.writer_canonical, do: run_writer(vector, nodes)
        if vector.measure_at_least, do: run_measure(vector, nodes)

        assert Serialize.bits_processed(reader) == vector.consumed,
               "#{vector.name}: consumed #{Serialize.bits_processed(reader)} bits, " <>
                 "the corpus states #{vector.consumed}"

        :ok
    end
  end

  defp check_params!(vector) do
    Enum.each(vector.params, fn {name, _text} ->
      operations = Map.get(@params_by_operation, name, [])

      unless vector.operation in operations do
        flunk(
          "#{vector.name}: no runner for parameter '#{name}' on operation " <>
            "'#{vector.operation}' [#{vector.file}]"
        )
      end
    end)

    if vector.steps != [] and vector.operation != "sequence" do
      flunk("#{vector.name}: steps are only meaningful on a sequence [#{vector.file}]")
    end
  end

  # ------------------------------------------------------------------
  # the reader leg
  # ------------------------------------------------------------------

  defp run_reader(vector, nodes) do
    stream = read_stream(vector.bytes)

    case {vector.expect, run_nodes(stream, seed(nodes))} do
      {{:refused, _reason}, {:ok, _stream, _values}} ->
        flunk("#{vector.name}: the read succeeded, the corpus requires refusal [#{vector.file}]")

      {{:refused, reason}, {:error, stream, index, _step}} ->
        # the refusal names the rule the corpus states: a refusal for any
        # other reason is a disagreement about the format
        assert_reason(vector, stream, reason, index)

        # Failure is terminal, and a sequence states its own successors:
        # every step after the failing one must fail too, however many
        # readable bits the stream still holds.
        nodes
        |> Enum.drop(index + 1)
        |> Enum.each(fn node ->
          case run_node(stream, node) do
            {:error, _stream, _step} ->
              :ok

            {:ok, _stream, _values} ->
              flunk(
                "#{vector.name}: a step succeeded after step #{index + 1} was refused; " <>
                  "failure must be terminal [#{vector.file}]"
              )
          end
        end)

        # and the same rule against a read the vector does not name, so
        # every refused vector carries the terminality check and not only
        # the sequences that spell a successor
        stream = assert_terminal(vector, stream)

        # the later refusals were echoes: the first reason stands
        assert_reason(vector, stream, reason, index)
        {:refused, stream}

      {_expect, {:error, stream, index, _step}} ->
        flunk(
          "#{vector.name}: step #{index + 1} was refused, the corpus requires the read to be " <>
            "accepted after #{Serialize.bits_processed(stream)} bits [#{vector.file}]"
        )

      {{_kind, entries}, {:ok, stream, values}} ->
        check_entries(vector, nodes, values, entries)
        {:accepted, stream, attach(nodes, values)}
    end
  end

  # STANDARD.md, "What a runner checks": for a refused vector, the stream
  # terminal, "a further read on the same stream also fails, consumes no
  # bits and writes nothing". The read is one this vector does not
  # name, so the check reaches every refusal and not only the sequences.
  defp assert_terminal(vector, stream) do
    before = Serialize.bits_processed(stream)

    case Serialize.serialize_bits(stream, @sentinel, 8) do
      {:error, stream} ->
        assert Serialize.bits_processed(stream) == before,
               "#{vector.name}: the read after the refusal consumed bits [#{vector.file}]"

        stream

      other ->
        flunk(
          "#{vector.name}: the stream accepted #{inspect(other)} after the refusal; " <>
            "failure is not terminal [#{vector.file}]"
        )
    end
  end

  defp assert_reason(vector, stream, reason, index) do
    actual = Serialize.refusal(stream)

    unless actual == reason do
      flunk(
        "#{vector.name}: step #{index + 1} was refused as #{inspect(actual)}, the corpus " <>
          "states #{reason} [#{vector.file}]"
      )
    end
  end

  # One entry per step in order, with `-` for a step that produces no value
  # of its own. A leading `preceding_bits` step carries no entry, so the
  # list aligns to the END of the step list.
  defp check_entries(vector, nodes, values, entries) do
    kinds = flatten_kinds(nodes)
    offset = length(values) - length(entries)

    if offset < 0 do
      flunk("#{vector.name}: the expect list states more values than the vector has steps")
    end

    entries
    |> Enum.with_index()
    |> Enum.each(fn {entry, index} ->
      kind = Enum.at(kinds, offset + index)
      value = Enum.at(values, offset + index)

      unless entry == "-" or matches?(vector, kind, value, entry) do
        flunk(
          "#{vector.name}: step #{offset + index + 1} decoded #{render(kind, value)}, " <>
            "the corpus states #{entry} [#{vector.file}]"
        )
      end
    end)
  end

  # ------------------------------------------------------------------
  # the writer leg
  # ------------------------------------------------------------------

  # A vector marked `writer = canonical` states the bytes a conforming
  # writer emits for its value, so the decoded steps go back through the
  # write stream and the comparison covers the WHOLE stream, flush
  # included. That is what pins the trailing-bits obligation: the unused
  # bits of the final byte must be zero, and a writer leaking anything into
  # them produces a byte the vector does not carry.
  defp run_writer(vector, nodes) do
    case run_nodes(WriteStream.new(), nodes) do
      {:error, _stream, index, _step} ->
        flunk("#{vector.name}: the writer refused step #{index + 1} of a canonical vector")

      {:ok, stream, _values} ->
        emitted = stream |> WriteStream.flush() |> WriteStream.data()

        assert emitted == vector.bytes,
               "#{vector.name}: the writer emitted #{hex_pairs(emitted)}, " <>
                 "the corpus states #{hex_pairs(vector.bytes)} [#{vector.file}]"
    end
  end

  # A vector carrying `writer_input` hands the writer that float32 and
  # states the bytes it must emit: the quantization arithmetic between
  # quanta, where the decoded value would not reproduce the input. It runs
  # whatever the reader leg expects.
  defp run_writer_input(vector, [%{kind: :compressed_float} = node]) do
    node = %{node | value: Float32.value32(vector.writer_input)}

    case run_nodes(WriteStream.new(), [node]) do
      {:ok, stream, _values} ->
        emitted = stream |> WriteStream.flush() |> WriteStream.data()

        assert emitted == vector.bytes,
               "#{vector.name}: handed #{render(:compressed_float, node.value)}, the writer " <>
                 "emitted #{hex_pairs(emitted)}, the corpus states #{hex_pairs(vector.bytes)} " <>
                 "[#{vector.file}]"
    end
  end

  defp run_writer_input(vector, _nodes) do
    flunk("#{vector.name}: writer_input is meaningful on compressed_float only [#{vector.file}]")
  end

  # ------------------------------------------------------------------
  # the measure leg
  # ------------------------------------------------------------------

  # STANDARD.md makes a measure a BOUND and not the packet size, so the
  # corpus states a floor and the check is an inequality. A measure that
  # computes alignment from a running bit index starting at zero
  # under-counts every unaligned start and falls below the floor, which is
  # the non-conforming accounting the document names.
  defp run_measure(vector, nodes) do
    case run_nodes(MeasureStream.new(), nodes) do
      {:error, _stream, index, _step} ->
        flunk(
          "#{vector.name}: the measure refused step #{index + 1}; " <>
            "a measure refuses nothing at runtime"
        )

      {:ok, stream, _values} ->
        measured = Serialize.bits_processed(stream)

        assert measured >= vector.measure_at_least,
               "#{vector.name}: measured #{measured} bits, the corpus requires at least " <>
                 "#{vector.measure_at_least} [#{vector.file}]"
    end
  end

  # ------------------------------------------------------------------
  # the step machine
  # ------------------------------------------------------------------

  defp run_nodes(stream, nodes), do: run_nodes(stream, nodes, 0, [])

  defp run_nodes(stream, [], _index, values), do: {:ok, stream, Enum.reverse(values)}

  defp run_nodes(stream, [node | rest], index, values) do
    case run_node(stream, node) do
      {:ok, stream, decoded} -> run_nodes(stream, rest, index + 1, Enum.reverse(decoded, values))
      {:error, stream, step} -> {:error, stream, index, step}
    end
  end

  # STANDARD.md, "object": the nested object's own serialize function is
  # invoked inline and contributes NO BYTES OF ITS OWN -- composition, not
  # an encoding, with no framing, length prefix or alignment around it. In
  # this port composition is a function call and nothing else, so the
  # nested steps run through one here, exactly as a caller's own nested
  # serialize function would.
  #
  # The composition is still a read on the stream, so it keeps the stream's
  # terminality as the reference's serialize_object does: a refused read
  # stream refuses the object on entry and on exit, with the latched reason,
  # even when the object is empty and its steps consume nothing.
  defp run_node(stream, %{kind: :object, steps: children} = node) do
    if failed?(stream) do
      {:error, stream, node}
    else
      case run_nodes(stream, children) do
        {:ok, stream, values} ->
          if failed?(stream),
            do: {:error, stream, node},
            else: {:ok, stream, [@no_value | values]}

        {:error, stream, _index, step} ->
          {:error, stream, step}
      end
    end
  end

  defp run_node(stream, step), do: run_step(stream, step)

  defp failed?(%ReadStream{} = stream), do: ReadStream.failed?(stream)
  defp failed?(_stream), do: false

  defp run_step(stream, %{kind: :bits} = step),
    do: wrap(step, Serialize.serialize_bits(stream, step.value, step.width))

  defp run_step(stream, %{kind: :bool} = step),
    do: wrap(step, Serialize.serialize_bool(stream, step.value))

  defp run_step(stream, %{kind: :uint128} = step),
    do: wrap(step, Serialize.serialize_uint128(stream, step.value))

  defp run_step(stream, %{kind: :align} = step),
    do: wrap(step, Serialize.serialize_align(stream))

  defp run_step(stream, %{kind: :end} = step),
    do: wrap(step, Serialize.serialize_end(stream))

  defp run_step(stream, %{kind: :int} = step),
    do: wrap(step, Serialize.serialize_int(stream, step.value, step.min, step.max))

  defp run_step(stream, %{kind: :int64} = step),
    do: wrap(step, Serialize.serialize_int64(stream, step.value, step.min, step.max))

  defp run_step(stream, %{kind: :int128} = step),
    do: wrap(step, Serialize.serialize_int128(stream, step.value, step.min, step.max))

  defp run_step(stream, %{kind: :int_relative} = step),
    do: wrap(step, Serialize.serialize_int_relative(stream, step.previous, step.value))

  defp run_step(stream, %{kind: :float} = step),
    do: wrap(step, Serialize.serialize_float(stream, step.value))

  defp run_step(stream, %{kind: :double} = step),
    do: wrap(step, Serialize.serialize_double(stream, step.value))

  defp run_step(stream, %{kind: :compressed_float} = step) do
    wrap(
      step,
      Serialize.serialize_compressed_float(stream, step.value, step.min, step.max, step.res)
    )
  end

  defp run_step(stream, %{kind: :bytes} = step),
    do: wrap(step, Serialize.serialize_bytes(stream, step.value, step.count))

  defp run_step(stream, %{kind: :string} = step),
    do: wrap(step, Serialize.serialize_string(stream, step.value, step.buffer_size))

  defp run_step(stream, %{kind: :fixed} = step) do
    wrap(
      step,
      Serialize.serialize_fixed(
        stream,
        step.value,
        step.integer_bits,
        step.fraction_bits,
        step.min,
        step.max
      )
    )
  end

  defp wrap(_step, {:ok, stream, value}), do: {:ok, stream, [value]}
  defp wrap(_step, {:ok, stream}), do: {:ok, stream, [@no_value]}
  defp wrap(step, {:error, stream}), do: {:error, stream, step}

  defp wrap(step, other) do
    flunk(
      "#{step.kind} returned #{inspect(other)}: a refusal hands back {:error, stream} and " <>
        "no value, so there is no destination it could have written"
    )
  end

  # ------------------------------------------------------------------
  # building the steps
  # ------------------------------------------------------------------

  # A single-operation vector becomes a one or two step sequence: the
  # operations whose interesting behavior only exists at a non-zero bit
  # index take a `preceding_bits` parameter, which becomes a leading bits
  # step.
  defp build_nodes(%{operation: "sequence"} = vector) do
    if vector.steps == [] do
      flunk("#{vector.name}: a sequence with no steps [#{vector.file}]")
    end

    vector.steps |> Enum.map(&step_from_words(vector, &1)) |> nest(vector)
  end

  defp build_nodes(vector) do
    leading =
      case param(vector, "preceding_bits") do
        nil -> []
        text -> preceding_bits_step(vector, number!(vector, "preceding_bits", text))
      end

    leading ++ [operation_step(vector)]
  end

  defp preceding_bits_step(_vector, 0), do: []
  defp preceding_bits_step(_vector, width), do: [%{kind: :bits, width: width, value: @sentinel}]

  defp operation_step(%{operation: "bits"} = vector),
    do: %{kind: :bits, width: int_param!(vector, "bits"), value: @sentinel}

  defp operation_step(%{operation: "bool"}), do: %{kind: :bool, value: @sentinel}
  defp operation_step(%{operation: "uint128"}), do: %{kind: :uint128, value: @sentinel}
  defp operation_step(%{operation: "align"}), do: %{kind: :align, value: @sentinel}
  defp operation_step(%{operation: "end"}), do: %{kind: :end, value: @sentinel}
  defp operation_step(%{operation: "float"}), do: %{kind: :float, value: @sentinel}
  defp operation_step(%{operation: "double"}), do: %{kind: :double, value: @sentinel}

  defp operation_step(%{operation: operation} = vector)
       when operation in ["int", "int64", "int128"] do
    %{
      kind: String.to_atom(operation),
      min: int_param!(vector, "min"),
      max: int_param!(vector, "max"),
      value: @sentinel
    }
  end

  defp operation_step(%{operation: "int_relative"} = vector),
    do: %{kind: :int_relative, previous: int_param!(vector, "previous"), value: @sentinel}

  defp operation_step(%{operation: "compressed_float"} = vector) do
    %{
      kind: :compressed_float,
      min: float_param!(vector, "min"),
      max: float_param!(vector, "max"),
      res: float_param!(vector, "res"),
      value: @sentinel
    }
  end

  defp operation_step(%{operation: "bytes"} = vector),
    do: %{kind: :bytes, count: int_param!(vector, "count"), value: @sentinel}

  defp operation_step(%{operation: "string"} = vector),
    do: %{kind: :string, buffer_size: int_param!(vector, "buffer_size"), value: @sentinel}

  # Every fixed point parameter is a compile-time constant of the C++ call
  # site, so a runner in a language that forces a table of declarations
  # carries one and fails a vector naming a declaration it lacks. This port
  # takes the four parameters at runtime, which STANDARD.md's `fixed`
  # section admits in as many words, so every declaration the corpus can
  # state is driven and none can be silently missing.
  defp operation_step(%{operation: "fixed"} = vector) do
    %{
      kind: :fixed,
      integer_bits: int_param!(vector, "integer_bits"),
      fraction_bits: int_param!(vector, "fraction_bits"),
      min: int_param!(vector, "min"),
      max: int_param!(vector, "max"),
      value: @sentinel
    }
  end

  defp operation_step(vector) do
    flunk("#{vector.name}: no runner for operation '#{vector.operation}' [#{vector.file}]")
  end

  # The step spellings inside a sequence, from the heads of
  # conformance/sequence.txt and conformance/object.txt.
  defp step_from_words(vector, text) do
    case String.split(text, " ", trim: true) do
      ["bits", n] -> %{kind: :bits, width: number!(vector, text, n), value: @sentinel}
      ["bool"] -> %{kind: :bool, value: @sentinel}
      ["align"] -> %{kind: :align, value: @sentinel}
      ["end"] -> %{kind: :end, value: @sentinel}
      ["float"] -> %{kind: :float, value: @sentinel}
      ["double"] -> %{kind: :double, value: @sentinel}
      ["uint128"] -> %{kind: :uint128, value: @sentinel}
      ["object", n] -> %{kind: :object, count: number!(vector, text, n), steps: []}
      ["bytes", n] -> %{kind: :bytes, count: number!(vector, text, n), value: @sentinel}
      ["string", n] -> %{kind: :string, buffer_size: number!(vector, text, n), value: @sentinel}
      ["int_relative", p] -> relative_step(vector, text, p)
      ["int", lo, hi] -> int_step(vector, text, :int, lo, hi)
      ["int64", lo, hi] -> int_step(vector, text, :int64, lo, hi)
      ["int128", lo, hi] -> int_step(vector, text, :int128, lo, hi)
      ["compressed_float", lo, hi, res] -> compressed_float_step(vector, text, lo, hi, res)
      ["fixed", ib, fb, lo, hi] -> fixed_step(vector, text, ib, fb, lo, hi)
      _other -> flunk("#{vector.name}: no runner for step '#{text}' [#{vector.file}]")
    end
  end

  defp int_step(vector, text, kind, lo, hi) do
    %{
      kind: kind,
      min: number!(vector, text, lo),
      max: number!(vector, text, hi),
      value: @sentinel
    }
  end

  defp relative_step(vector, text, previous) do
    %{kind: :int_relative, previous: number!(vector, text, previous), value: @sentinel}
  end

  defp compressed_float_step(vector, text, min, max, res) do
    %{
      kind: :compressed_float,
      min: float!(vector, text, min),
      max: float!(vector, text, max),
      res: float!(vector, text, res),
      value: @sentinel
    }
  end

  defp fixed_step(vector, text, integer_bits, fraction_bits, min, max) do
    %{
      kind: :fixed,
      integer_bits: number!(vector, text, integer_bits),
      fraction_bits: number!(vector, text, fraction_bits),
      min: number!(vector, text, min),
      max: number!(vector, text, max),
      value: @sentinel
    }
  end

  # `object <n>` wraps the NEXT n steps, so the flat step list becomes a
  # tree whose top level is what the terminality rule walks.
  defp nest([], _vector), do: []

  defp nest(steps, vector) do
    {[node], rest} = take(steps, 1, vector)
    [node | nest(rest, vector)]
  end

  defp take(steps, 0, _vector), do: {[], steps}

  defp take([], _count, vector) do
    flunk("#{vector.name}: an object claims more steps than the sequence has [#{vector.file}]")
  end

  defp take([%{kind: :object, count: count} = node | rest], remaining, vector) do
    {children, rest} = take(rest, count, vector)
    {siblings, rest} = take(rest, remaining - 1, vector)
    {[%{node | steps: children} | siblings], rest}
  end

  defp take([node | rest], remaining, vector) do
    {siblings, rest} = take(rest, remaining - 1, vector)
    {[node | siblings], rest}
  end

  # ------------------------------------------------------------------
  # values in and out of the tree
  # ------------------------------------------------------------------

  defp seed(nodes) do
    Enum.map(nodes, fn
      %{kind: :object} = node -> %{node | steps: seed(node.steps)}
      node -> %{node | value: @sentinel}
    end)
  end

  # the decoded values, in the preorder the expect list uses: an object
  # states its own `-` entry before the entries of the steps it wraps
  defp flatten_kinds(nodes) do
    Enum.flat_map(nodes, fn
      %{kind: :object} = node -> [:object | flatten_kinds(node.steps)]
      node -> [node.kind]
    end)
  end

  defp attach(nodes, values) do
    {nodes, []} = attach_nodes(nodes, values)
    nodes
  end

  defp attach_nodes([], values), do: {[], values}

  defp attach_nodes([%{kind: :object} = node | rest], [_own | values]) do
    {children, values} = attach_nodes(node.steps, values)
    {siblings, values} = attach_nodes(rest, values)
    {[%{node | steps: children} | siblings], values}
  end

  defp attach_nodes([node | rest], [value | values]) do
    {siblings, values} = attach_nodes(rest, values)
    {[%{node | value: value} | siblings], values}
  end

  # ------------------------------------------------------------------
  # expectations
  # ------------------------------------------------------------------

  # Numeric values -- every integer width, and the float, double and
  # compressed_float bit patterns -- compare as 128-bit two's complement
  # PATTERNS, so a hexadecimal expectation and its decimal twin are one
  # expectation and nothing goes through a float. The remaining kinds have
  # textual spellings the corpus states directly.
  defp matches?(vector, kind, value, entry) when kind in @pattern_kinds do
    pattern(bits_of(kind, value)) == pattern(number!(vector, "expect", entry))
  end

  defp matches?(vector, kind, value, entry) when kind in @number_kinds do
    pattern(value) == pattern(number!(vector, "expect", entry))
  end

  defp matches?(_vector, kind, value, entry), do: render(kind, value) == entry

  defp pattern(value), do: Bitwise.band(value, @mask128)

  defp bits_of(:bits, value), do: value
  defp bits_of(:uint128, value), do: value
  defp bits_of(:float, value), do: Float32.bits32(value)
  defp bits_of(:compressed_float, value), do: Float32.bits32(value)
  defp bits_of(:double, value), do: Float32.bits64(value)

  defp render(kind, value) when kind in @pattern_kinds,
    do: "0x" <> String.pad_leading(Integer.to_string(bits_of(kind, value), 16), 32, "0")

  defp render(kind, value) when kind in @number_kinds, do: Integer.to_string(value)
  defp render(:bool, value), do: to_string(value)
  defp render(:align, _value), do: "0"
  defp render(:end, _value), do: "0"
  defp render(:object, _value), do: "0"
  defp render(kind, value) when kind in [:bytes, :string], do: hex_pairs(value)

  defp hex_pairs(binary) do
    for(<<byte <- binary>>, do: String.pad_leading(Integer.to_string(byte, 16), 2, "0"))
    |> Enum.join(" ")
  end

  # ------------------------------------------------------------------
  # parameters and numbers
  # ------------------------------------------------------------------

  defp read_stream(bytes) do
    padded = bytes <> :binary.copy(<<@slack_fill>>, @slack)
    ReadStream.new(:binary.part(padded, 0, byte_size(bytes)))
  end

  defp param(vector, name) do
    case List.keyfind(vector.params, name, 0) do
      {^name, text} -> text
      nil -> nil
    end
  end

  defp int_param!(vector, name) do
    case param(vector, name) do
      nil -> flunk("#{vector.name}: operation '#{vector.operation}' needs parameter '#{name}'")
      text -> number!(vector, name, text)
    end
  end

  # `res` under compressed_float is a float32, and so are that operation's
  # own min and max: values are typed by the operation's table.
  defp float_param!(vector, name) do
    text = param(vector, name)

    case text && Float.parse(text) do
      {number, ""} ->
        number

      _other ->
        flunk("#{vector.name}: parameter '#{name}' is not a float32: #{inspect(text)}")
    end
  end

  # A compressed_float step spells its three float32 bounds as words rather
  # than as parameters, and a whole number among them is spelled without a
  # fractional part.
  defp float!(vector, what, text) do
    case Float.parse(text) do
      {number, ""} ->
        number

      _other ->
        flunk("#{vector.name}: '#{text}' is not a float32, in #{what} [#{vector.file}]")
    end
  end

  # Numbers are signed decimal or 0x hexadecimal, and a parser must accept
  # values up to 128 bits wide. BEAM integers are arbitrary precision, so
  # the width costs nothing here.
  defp number!(vector, what, text) do
    case parse_number(text) do
      {:ok, number} -> number
      :error -> flunk("#{vector.name}: '#{text}' is not a number, in #{what} [#{vector.file}]")
    end
  end

  defp parse_number("-" <> rest) do
    with {:ok, number} <- parse_number(rest), do: {:ok, -number}
  end

  defp parse_number("+" <> rest), do: parse_number(rest)
  defp parse_number("0x" <> rest), do: parse_base(rest, 16)
  defp parse_number("0X" <> rest), do: parse_base(rest, 16)
  defp parse_number(text), do: parse_base(text, 10)

  defp parse_base("", _base), do: :error

  defp parse_base(text, base) do
    case Integer.parse(text, base) do
      {number, ""} -> {:ok, number}
      _other -> :error
    end
  end
end
