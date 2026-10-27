defmodule Serialize.ControlsTest do
  @moduledoc """
  The NEGATIVE CONTROLS. The corpus is the conformance instrument, and an
  instrument nobody has seen go red is a claim rather than a measurement
  (STANDARD.md, "The conformance corpus"). Two kinds of control prove it
  responds:

    * The unknown operation control runs the runner over
      `conformance-controls/unknown-operation.txt`, a vector whose operation
      has no runner, and requires it to go RED rather than skip it. A
      `wstring` vector, an operation format 2.0 removed, is run the same way.
    * Every other control is a reader with ONE refusal rule deleted, run
      against the real corpus. It passes only when the vectors that fail are
      EXACTLY the ones `conformance-controls/<rule>.expected` names: a
      sabotage that breaks more than its rule, or less, is a control that
      measures something other than what it claims. The lists are vendored
      verbatim from the reference, which builds the same sabotage of its own
      reader from the same lists.

  A sabotage is a string replacement in the library source, compiled into
  the running VM in place of the real module, and the real source is
  compiled back afterwards. A needle that stops matching FAILS the control
  rather than passing as a no-op: a control that has quietly stopped
  sabotaging anything is worse than no control at all. If one fails, update
  the needle; never delete the control. Each replacement keeps the line
  compiling and reading every variable the deleted rule read: the added
  conjunct is false exactly when the rule would have fired.

  Because the controls swap modules in the running VM they are excluded from
  the default run, and run on their own:

      mix test --only controls
  """

  use ExUnit.Case, async: false

  alias Serialize.{ConformanceRunner, ConformanceVectors}

  @moduletag :controls

  @lib Path.expand("../lib", __DIR__)
  @controls_dir ConformanceVectors.controls_dir()

  @deleted " # NEGATIVE CONTROL: this rule is deleted on purpose"

  @controls [
    {"align-padding", "readers must verify that the alignment padding bits are zero",
     [
       {"serialize/read_stream.ex",
        "          BitReader.decode_bits(stream.data, stream.bits_read, bits) != 0 ->",
        "          BitReader.decode_bits(stream.data, stream.bits_read, bits) == 0xFFFFFFFF ->" <>
          @deleted}
     ]},

    # the ranged int's two rules, at the 32-bit site only: the bounded tiers
    # of int_relative and a string's length are ranged ints and fall with it,
    # while int64, int128 and fixed keep their own sites, as in the reference
    {"ranged-reconstruction", "a ranged int decodes to its offset plus min",
     [
       {"serialize/read_stream.ex", "          {:ok, read, min + offset32}",
        "          {:ok, read, offset32}" <> @deleted}
     ]},
    {"ranged-range", "a ranged int whose offset is past the span is refused",
     [
       # the widened right hand side is at least 0xFFFFFFFF and the offset is at most 0xFFFFFFFF
       {"serialize/read_stream.ex", "        if offset32 > max - min do",
        "        if offset32 > max - min + 0xFFFFFFFF do" <> @deleted}
     ]},

    # the degenerate fixed point field consumes no bits and would otherwise
    # always succeed: fixed point is the 128-bit ranged codec over the raw
    # bounds here, so the latch is deleted for a degenerate range at that site
    {"fixed-degenerate-terminal",
     "every read consults the failure state, zero bit reads included",
     [
       {"serialize/read_stream.ex",
        "  def serialize_integer128(%__MODULE__{failed: true} = stream, _value, _min, _max),",
        "  def serialize_integer128(%__MODULE__{failed: true} = stream, _value, min, max) when min != max," <>
          @deleted}
     ]},

    # the finite rule, once per width and once for the compressed float
    # decode: zero is finite, so the added conjunct never holds
    {"float-finite", "a float read refuses NaN and the infinities",
     [
       {"serialize.ex", "      if not Float32.finite32?(pattern) do",
        "      if not Float32.finite32?(pattern) and pattern == 0 do" <> @deleted}
     ]},
    {"double-finite", "a double read refuses NaN and the infinities",
     [
       {"serialize.ex", "      if not Float32.finite64?(pattern) do",
        "      if not Float32.finite64?(pattern) and pattern == 0 do" <> @deleted}
     ]},
    {"compressed-float-finite", "a compressed float decode that is not finite is refused",
     [
       {"serialize.ex",
        "  defp read_compressed_float(stream, decoded) when not is_float(decoded),",
        "  defp read_compressed_float(stream, decoded) when not is_float(decoded) and decoded == 0," <>
          @deleted}
     ]},

    # without the trailing data rule the end reads whatever remains as its
    # padding, so a stream with whole bytes left passes when they are zero
    {"end-trailing-data", "an end refuses a whole byte after the object",
     [
       {"serialize/read_stream.ex", "    if remaining >= 8 do",
        "    if remaining >= 8 and stream.bits_read < 0 do" <> @deleted}
     ]},
    {"end-padding", "an end refuses non-zero padding in the final byte",
     [
       {"serialize/read_stream.ex", "    if padding != 0 do",
        "    if padding == 0xFFFFFFFF do" <> @deleted}
     ]},
    {"int-relative-canonical", "the absolute tier refuses a difference a bounded tier carries",
     [
       {"serialize.ex",
        "      tier == :absolute and reconstructed - previous <= @relative_bounded_max ->",
        "      tier == :absolute and reconstructed - previous <= @relative_bounded_max and reconstructed < 0 ->" <>
          @deleted}
     ]},
    {"string-embedded-nul", "a string read refuses a zero byte among its payload",
     [
       {"serialize.ex", "          :binary.match(payload, <<0>>) != :nomatch ->",
        "          :binary.match(payload, <<0>>) != :nomatch and byte_size(payload) < 0 ->" <>
          "\n" <> @deleted <> "\n"}
     ]},
    {"string-utf8", "a string read refuses a payload that is not well formed UTF-8",
     [
       {"serialize.ex", "          not String.valid?(payload) ->",
        "          not String.valid?(payload) and byte_size(payload) < 0 ->" <>
          "\n" <> @deleted <> "\n"}
     ]},

    # One clause of the UTF-8 rule alone: the encoded surrogates, ED A0 80
    # through ED BF BF. This port validates with the platform's validator,
    # String.valid?/1, which has no clause to delete, so the control is
    # ADAPTED: the sabotaged reader masks every encoded surrogate with a
    # well-formed three byte sequence before it validates, which is a
    # validator without the surrogate clause and with every other one.
    {"string-utf8-surrogate", "a string read refuses an encoded surrogate code point",
     [
       {"serialize.ex", "          not String.valid?(payload) ->",
        "          not String.valid?(Regex.replace(~r/\\xED[\\xA0-\\xBF][\\x80-\\xBF]/, payload, \"\\u{E000}\")) ->" <>
          "\n" <> @deleted <> "\n"}
     ]},

    # a reader whose ranged 64 bit integer passes through a double, as a port
    # backed by a double number type would: every integer up to 2^53
    # survives, and the wide vectors past it do not. The clamp at the top is
    # the reference's, whose conversion back to int64 saturates there.
    {"int64-through-double", "a 64 bit value is carried exactly, never through a double",
     [
       {"serialize/read_stream.ex", "          {:ok, read, min + offset64}",
        "          {:ok, read, Kernel.min(trunc((min + offset64) * 1.0), 0x7FFFFFFFFFFFFFFF)} # NEGATIVE CONTROL: the value goes through a double on purpose"}
     ]},

    # A nested object on a failed stream refuses, on entry and on exit. This
    # port composes nested objects with plain calls, so the rule lives in the
    # runner's composition rather than in lib/, and the sabotage patches the
    # runner: both checks go, since either alone refuses an empty object.
    {"object-terminal", "a nested object on a failed stream refuses",
     [
       {"../test/support/conformance_runner.ex", "    if failed?(stream) do",
        "    if failed?(stream) and node == nil do" <> @deleted},
       {"../test/support/conformance_runner.ex", "          if failed?(stream),",
        "          if failed?(stream) and node == nil," <> @deleted}
     ]},

    # the refusal reason: this reader refuses every stream the real one
    # refuses, and names the wrong rule for one of them
    {"wrong-reason", "a refusal names the rule that refused it",
     [
       {"serialize.ex", "refuse(stream, :embedded_nul)",
        "refuse(stream, :invalid_utf8) # NEGATIVE CONTROL: the wrong reason on purpose\n"}
     ]}
  ]

  for {name, rule, patches} <- @controls do
    @name name
    @patches patches

    test "control #{name}: #{rule}" do
      failing = with_sabotage(@patches, &failing_vectors/0)
      expected = expected(@name)

      assert failing == expected,
             "control #{@name} failed the wrong vectors.\n" <>
               "  failed but not expected: #{inspect(failing -- expected)}\n" <>
               "  expected but passed: #{inspect(expected -- failing)}"
    end
  end

  test "every vendored .expected list has a control here, and every control a list" do
    vendored =
      @controls_dir
      |> Path.join("*.expected")
      |> Path.wildcard()
      |> Enum.map(&Path.basename(&1, ".expected"))
      |> Enum.sort()

    assert vendored == @controls |> Enum.map(&elem(&1, 0)) |> Enum.sort()
  end

  test "control unknown-operation: a vector whose operation has no runner goes red" do
    [vector] = ConformanceVectors.parse_file(Path.join(@controls_dir, "unknown-operation.txt"))
    assert_raise ExUnit.AssertionError, fn -> ConformanceRunner.run_vector(vector) end
  end

  test "control unknown-operation: wstring, removed by format 2.0, is an unknown operation" do
    operation = %ConformanceVectors{
      file: "wstring.txt",
      operation: "wstring",
      name: "control-wstring-is-gone",
      bytes: <<0x00>>,
      expect: {:value, [""]},
      consumed: 3
    }

    step = %ConformanceVectors{
      file: "sequence.txt",
      operation: "sequence",
      name: "control-wstring-step-is-gone",
      steps: ["wstring 8"],
      bytes: <<0x00>>,
      expect: {:value, [""]},
      consumed: 3
    }

    assert_raise ExUnit.AssertionError, fn -> ConformanceRunner.run_vector(operation) end
    assert_raise ExUnit.AssertionError, fn -> ConformanceRunner.run_vector(step) end
  end

  # ------------------------------------------------------------------
  # the machinery
  # ------------------------------------------------------------------

  # The names of the corpus vectors this reader fails, sorted.
  defp failing_vectors do
    ConformanceVectors.all()
    |> Enum.reject(fn vector ->
      try do
        ConformanceRunner.run_vector(vector) == :ok
      rescue
        _error -> false
      end
    end)
    |> Enum.map(& &1.name)
    |> Enum.sort()
  end

  defp expected(name) do
    @controls_dir
    |> Path.join("#{name}.expected")
    |> File.read!()
    |> String.split("\n")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == "" or String.starts_with?(&1, "#")))
    |> Enum.sort()
  end

  # Compiles the patched sources in place of the real modules, runs `fun`,
  # and compiles the real sources back, whatever happens.
  defp with_sabotage(patches, fun) do
    sources =
      patches
      |> Enum.map(&elem(&1, 0))
      |> Enum.uniq()
      |> Map.new(fn file -> {file, File.read!(Path.join(@lib, file))} end)

    sabotaged =
      Enum.reduce(patches, sources, fn {file, needle, replacement}, acc ->
        text = Map.fetch!(acc, file)

        unless String.contains?(text, needle) do
          flunk("the needle #{inspect(needle)} matches nothing in lib/#{file}: update it")
        end

        Map.put(acc, file, String.replace(text, needle, replacement))
      end)

    try do
      compile(sabotaged)
      fun.()
    after
      compile(sources)
    end
  end

  defp compile(sources) do
    previous = Code.get_compiler_option(:ignore_module_conflict)
    Code.put_compiler_option(:ignore_module_conflict, true)

    try do
      {_result, _diagnostics} =
        Code.with_diagnostics(fn ->
          Enum.each(sources, fn {file, text} ->
            Code.compile_string(text, Path.join(@lib, file))
          end)
        end)
    after
      Code.put_compiler_option(:ignore_module_conflict, previous)
    end
  end
end
