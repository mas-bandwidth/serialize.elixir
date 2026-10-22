defmodule Serialize.ConformanceTest do
  @moduledoc """
  The shared conformance corpus, run through this port's reader, writer and
  measure.

  STANDARD.md, "The conformance corpus": "A runner discovers the directory
  and runs every vector in it." The corpus is the instrument the standard names, and
  the obligations it states are the ones this module meets:

    * The directory is **discovered**, never named file by file. An empty
      directory fails the run, because an empty corpus is a broken checkout
      and not a pass.
    * A vector whose operation this runner cannot drive **fails**. So does a
      vector naming a parameter the runner does not understand, and a step
      spelling it has no code for. Nothing is ever skipped.
    * **One step machine** drives the single-operation files and the
      `sequence`, `object` and `message` files alike. A single-operation
      vector is a one or two step sequence built from the record's own
      parameters, so the sequence files cannot drift away from the operation
      files.
    * For an **accepted** vector: the decoded value equals the record's, and
      the bits consumed equal `consumed`.
    * For `writer = canonical`: the decoded values go back through the WRITE
      stream and the whole emitted stream matches byte for byte, flush
      included. That is where the trailing-bits obligation bites — the
      unused bits of the final byte must be zero.
    * For `writer_input`: the writer is handed that float32 and the
      emitted stream matches the record's bytes, on refused vectors too.
    * For `measure_at_least`: the MEASURE stream over the same steps must
      report at least the floor. A measure is a bound and not the packet
      size, so the check is an inequality and never an equality.
    * For a **refused** vector: the read is refused for the reason the
      record states, the caller's destination is unwritten, every later
      step refuses however many readable bits remain, the stream is left
      TERMINAL, and its reason is still the first one.

  Terminality is checked by BEHAVIOR and never by an accessor, so the check
  is the family's and not this port's: after a refusal a further read the
  vector does not name must also fail, consume no bits, and write nothing.
  This port's refusal hands back `{:error, stream}` with no third element,
  so there is no destination a refused read could write — the assertions
  in `Serialize.ConformanceRunner` require that shape rather than assuming
  it.

  The expectations come from the corpus, never from this port.
  """

  use ExUnit.Case, async: true

  alias Serialize.{ConformanceRunner, ConformanceVectors}

  for path <- ConformanceVectors.files() do
    @external_resource path
  end

  @vectors ConformanceVectors.all()
  @vector_count length(@vectors)

  test "the corpus is discovered, and an empty corpus fails the run" do
    assert ConformanceVectors.files() != [],
           "conformance/ is empty: vendor it from mas-bandwidth/serialize"

    # the generated tests below are fixed at compile time; this compares
    # them against the corpus on disk, so a stale build cannot pass by
    # running fewer vectors than the corpus holds
    assert length(ConformanceVectors.all()) == @vector_count
    assert @vector_count > 0
  end

  for vector <- @vectors do
    @vector vector

    test "#{vector.file} #{vector.name}" do
      ConformanceRunner.run_vector(@vector)
    end
  end
end
