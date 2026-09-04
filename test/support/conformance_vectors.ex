defmodule Serialize.ConformanceVectors do
  @moduledoc """
  Reader for the shared conformance corpus vendored in `conformance/`.

  The corpus is the conformance instrument STANDARD.md names, one file per
  operation, vendored verbatim from `mas-bandwidth/serialize` and held to
  it by a CI sync check. Nothing here reimplements the codec or
  regenerates an expectation: the vectors carry the bytes and the verdict,
  and `Serialize.ConformanceTest` runs each one through this port's
  reader.

  The file format is STANDARD.md, "The vector format": `#` begins a
  comment, blank lines separate records, and each record is a `key` and
  its value one per line — `operation`, `name`, `param` repeated as
  `name = value`, `bytes` as hexadecimal pairs (empty for a zero-bit
  read), `expect` as the word `refused` or `value = ` and the decoded
  value, and `consumed` on accepted reads only.
  """

  defstruct operation: nil, name: nil, params: %{}, bytes: <<>>, expect: nil, consumed: nil

  @type t :: %__MODULE__{
          operation: String.t(),
          name: String.t(),
          params: %{String.t() => integer},
          bytes: binary,
          expect: :refused | {:value, integer},
          consumed: non_neg_integer | nil
        }

  @dir Path.expand("../../conformance", __DIR__)

  @doc "The vendored corpus directory."
  @spec dir() :: String.t()
  def dir, do: @dir

  @doc "The corpus files, sorted by name."
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
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&String.starts_with?(&1, "#"))
    |> Enum.chunk_by(&(&1 == ""))
    |> Enum.reject(&(&1 == [""]))
    |> Enum.map(&parse_record/1)
  end

  defp parse_record(lines), do: Enum.reduce(lines, %__MODULE__{}, &parse_line/2)

  defp parse_line(line, record) do
    case String.split(line, " ", parts: 2) do
      ["operation", value] ->
        %{record | operation: value}

      ["name", value] ->
        %{record | name: value}

      ["param", value] ->
        [name, number] = String.split(value, " = ", parts: 2)
        %{record | params: Map.put(record.params, name, String.to_integer(number))}

      ["bytes"] ->
        %{record | bytes: <<>>}

      ["bytes", value] ->
        %{record | bytes: hex(value)}

      ["expect", "refused"] ->
        %{record | expect: :refused}

      ["expect", "value = " <> number] ->
        %{record | expect: {:value, String.to_integer(number)}}

      ["consumed", value] ->
        %{record | consumed: String.to_integer(value)}
    end
  end

  defp hex(value) do
    value
    |> String.split(" ", trim: true)
    |> Enum.map(&String.to_integer(&1, 16))
    |> :erlang.list_to_binary()
  end
end
