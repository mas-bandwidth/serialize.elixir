defmodule Serialize.CorpusRootTest do
  @moduledoc """
  The corpus root override, a unit test: unset and empty are the repository
  (the vendored copy), a named directory is read in place of it, and a root
  that holds no vectors discovers none, so the conformance run's empty-corpus
  assertion is red. The scratch root is ExUnit's tmp_dir, inside the project.
  """

  use ExUnit.Case, async: true

  alias Serialize.ConformanceVectors

  @repository Path.expand("..", __DIR__)

  test "unset and empty SERIALIZE_CORPUS_DIR are the repository" do
    assert ConformanceVectors.root(nil) == @repository
    assert ConformanceVectors.root("") == @repository
  end

  @tag :tmp_dir
  test "SERIALIZE_CORPUS_DIR names the corpus root", %{tmp_dir: tmp_dir} do
    assert ConformanceVectors.root(tmp_dir) == tmp_dir

    conformance = Path.join(tmp_dir, "conformance")
    File.mkdir_p!(conformance)
    file = Path.join(conformance, "bool.txt")

    File.write!(file, """
    operation bool
    name override-true
    bytes 01
    expect value = true
    consumed 1
    """)

    assert ConformanceVectors.files(conformance) == [file]
    assert [%ConformanceVectors{name: "override-true"}] = ConformanceVectors.parse_file(file)
    assert ConformanceVectors.files(Path.join(tmp_dir, "missing")) == []
  end
end
