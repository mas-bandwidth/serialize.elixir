defmodule Serialize.ConformanceVectors do
  @moduledoc """
  Reader for the shared conformance corpus vendored in `conformance/`.

  The corpus is the conformance instrument STANDARD.md names, one file per
  covered operation, vendored verbatim from `mas-bandwidth/serialize` and
  held to it by a CI sync check. Nothing here reimplements the codec or
  regenerates an expectation: the vectors carry the bytes and the verdict,
  and `Serialize.ConformanceTest` runs each one through this port's reader,
  writer and measure.

  The directory is DISCOVERED and never named file by file, so a newly
  vendored file runs without anyone editing a list: `files/0` globs the
  directory, and the test module marks each result an `@external_resource`
  so a vendored change recompiles the suite.

  The file format is STANDARD.md, "The vector format": `#` begins a comment
  at the start of a line and nowhere else, blank lines separate records,
  and each record is a `key` and its value one per line.

  | key | meaning |
  |---|---|
  | `operation` | the operation under test, once per record |
  | `name` | a stable identifier for the vector |
  | `param` | one parameter as `name = value`, repeated per parameter |
  | `bytes` | the stream as hexadecimal pairs, empty for a zero-bit read |
  | `expect` | `refused`, or `value = ` / `bits = 0x` and the decoded value |
  | `consumed` | bits a conforming reader consumes, accepted reads only |
  | `writer` | `canonical`, on a vector that also pins the emitted bytes |
  | `measure_at_least` | the floor a conforming measure may report |

  Parameter values stay as text here. They are typed by the operation's own
  table — `res` under `compressed_float` is a `float32` where `min` under
  `int128` is a 128-bit integer — so the runner parses each one at the type
  its operation gives it. An unknown key or a malformed line raises: a
  corpus this reader cannot read is a broken instrument, not a pass.
  """

  defstruct file: nil,
            operation: nil,
            name: nil,
            params: [],
            steps: [],
            bytes: <<>>,
            expect: nil,
            consumed: nil,
            measure_at_least: nil,
            writer_canonical: false

  @type expect :: :refused | {:value | :bits, [String.t()]}

  @type t :: %__MODULE__{
          file: String.t(),
          operation: String.t(),
          name: String.t(),
          params: [{String.t(), String.t()}],
          steps: [String.t()],
          bytes: binary,
          expect: expect,
          consumed: non_neg_integer | nil,
          measure_at_least: non_neg_integer | nil,
          writer_canonical: boolean
        }

  @dir Path.expand("../../conformance", __DIR__)

  @doc "The vendored corpus directory."
  @spec dir() :: String.t()
  def dir, do: @dir

  @doc "The corpus files, discovered from the directory and sorted by name."
  @spec files() :: [String.t()]
  def files, do: @dir |> Path.join("*.txt") |> Path.wildcard() |> Enum.sort()

  @doc "Every vector in the corpus, in file order."
  @spec all() :: [t]
  def all, do: Enum.flat_map(files(), &parse_file/1)

  @doc "Every vector in one corpus file, in file order."
  @spec parse_file(String.t()) :: [t]
  def parse_file(path) do
    path
    |> File.read!()
    |> String.split("\n")
    |> Enum.reject(&String.starts_with?(&1, "#"))
    |> Enum.map(&String.trim/1)
    |> Enum.chunk_by(&(&1 == ""))
    |> Enum.reject(fn chunk -> Enum.all?(chunk, &(&1 == "")) end)
    |> Enum.map(&parse_record(&1, path))
  end

  defp parse_record(lines, path) do
    record = Enum.reduce(lines, %__MODULE__{file: Path.basename(path)}, &parse_line(&1, &2, path))

    if record.operation == nil or record.name == nil or record.expect == nil do
      raise "#{path}: a record states no operation, no name or no expectation: #{inspect(lines)}"
    end

    %{record | params: Enum.reverse(record.params), steps: Enum.reverse(record.steps)}
  end

  defp parse_line(line, record, path) do
    case String.split(line, " ", parts: 2) do
      ["operation", value] ->
        %{record | operation: value}

      ["name", value] ->
        %{record | name: value}

      ["param", value] ->
        parse_param(value, record, path)

      ["bytes"] ->
        %{record | bytes: <<>>}

      ["bytes", value] ->
        %{record | bytes: hex(value, path)}

      ["expect", value] ->
        %{record | expect: parse_expect(value, path)}

      ["consumed", value] ->
        %{record | consumed: String.to_integer(value)}

      ["measure_at_least", value] ->
        %{record | measure_at_least: String.to_integer(value)}

      ["writer", "canonical"] ->
        %{record | writer_canonical: true}

      other ->
        raise "#{path}: unknown line #{inspect(other)}"
    end
  end

  # `param step = ...` collects into the step list, in order; everything
  # else is a named parameter of the operation. Both keep their text.
  defp parse_param(value, record, path) do
    case String.split(value, "=", parts: 2) do
      [name, text] ->
        name = String.trim(name)
        text = String.trim(text)

        if name == "step" do
          %{record | steps: [text | record.steps]}
        else
          %{record | params: [{name, text} | record.params]}
        end

      _other ->
        raise "#{path}: malformed param line: #{inspect(value)}"
    end
  end

  # `expect value` lists one entry per step separated by ` | `, with `-` for
  # a step that produces no value of its own. `expect bits = 0x...` is the
  # same list, spelled for a value compared as a bit pattern.
  defp parse_expect("refused", _path), do: :refused

  defp parse_expect(value, path) do
    case String.split(value, "=", parts: 2) do
      [kind, entries] ->
        entries = entries |> String.split("|") |> Enum.map(&String.trim/1)

        case String.trim(kind) do
          "value" -> {:value, entries}
          "bits" -> {:bits, entries}
          other -> raise "#{path}: unknown expect kind #{inspect(other)}"
        end

      _other ->
        raise "#{path}: malformed expect line: #{inspect(value)}"
    end
  end

  defp hex(value, path) do
    value
    |> String.split(" ", trim: true)
    |> Enum.map(fn pair ->
      case Integer.parse(pair, 16) do
        {byte, ""} when byte >= 0 and byte <= 255 -> byte
        _other -> raise "#{path}: malformed bytes line: #{inspect(value)}"
      end
    end)
    |> :erlang.list_to_binary()
  end
end
