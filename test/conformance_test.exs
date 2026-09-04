defmodule Serialize.ConformanceTest do
  @moduledoc """
  The shared conformance corpus, run through this port's reader.

  STANDARD.md, Provenance: "Every implementation vendors and syncs that
  directory the way it vendors this document, and its test suite must run
  every vector in it." An accepted vector must yield its value and consume
  exactly the stated bits; a refused vector must refuse. The expectations
  come from the corpus, never from this port.
  """

  use ExUnit.Case, async: true

  alias Serialize.{ConformanceVectors, ReadStream}

  for path <- ConformanceVectors.files() do
    @external_resource path
  end

  @vectors ConformanceVectors.all()
  @vector_count length(@vectors)

  test "every vector in the vendored corpus has a test" do
    assert ConformanceVectors.files() != [],
           "conformance/ is empty: vendor it from mas-bandwidth/serialize"

    # the generated tests below are fixed at compile time; this compares
    # them against the corpus on disk, so a stale build cannot pass by
    # running fewer vectors than the corpus holds
    assert length(ConformanceVectors.all()) == @vector_count
  end

  # after a refusal the stream position is not part of the contract, so a
  # refused vector states no `consumed` and only the verdict is asserted
  for vector <- @vectors, vector.expect == :refused do
    @vector vector

    test "#{vector.operation}: #{vector.name} is refused" do
      assert {:error, _stream} = read(@vector)
    end
  end

  for vector <- @vectors, match?({:value, _}, vector.expect) do
    @vector vector

    test "#{vector.operation}: #{vector.name}" do
      {:value, expected} = @vector.expect
      assert {:ok, reader, ^expected} = read(@vector)
      assert Serialize.bits_processed(reader) == @vector.consumed
    end
  end

  defp read(%{operation: "int_relative", params: %{"previous" => previous}, bytes: bytes}) do
    Serialize.serialize_int_relative(ReadStream.new(bytes), previous, nil)
  end

  defp read(%{operation: "int128", params: %{"min" => min, "max" => max}, bytes: bytes}) do
    Serialize.serialize_int128(ReadStream.new(bytes), nil, min, max)
  end

  defp read(%{operation: operation, name: name}) do
    flunk("the corpus carries #{operation}/#{name}, which this suite does not run")
  end
end
