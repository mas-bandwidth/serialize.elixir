defmodule Serialize.BitsRequiredTest do
  use ExUnit.Case, async: true

  import Bitwise

  alias Serialize.Bits

  # serialize.h test_bits_required
  test "bits_required over the 32-bit domain" do
    assert Bits.bits_required(0, 0) == 0
    assert Bits.bits_required(0, 1) == 1
    assert Bits.bits_required(0, 2) == 2
    assert Bits.bits_required(0, 3) == 2
    assert Bits.bits_required(0, 4) == 3
    assert Bits.bits_required(0, 5) == 3
    assert Bits.bits_required(0, 6) == 3
    assert Bits.bits_required(0, 7) == 3
    assert Bits.bits_required(0, 8) == 4
    assert Bits.bits_required(0, 255) == 8
    assert Bits.bits_required(0, 65_535) == 16
    assert Bits.bits_required(0, 4_294_967_295) == 32
  end

  # serialize.h test_bits_required64
  test "bits_required over the 64-bit domain" do
    assert Bits.bits_required(0, 4_294_967_296) == 33
    assert Bits.bits_required(0, 1 <<< 40) == 41
    assert Bits.bits_required(0, 0xFFFFFFFFFFFFFFFF) == 64
    assert Bits.bits_required(-0x8000000000000000, 0x7FFFFFFFFFFFFFFF) == 64
    assert Bits.bits_required(-5_000_000_000, 5_000_000_000) == 34
  end

  # serialize.h test_bits_required128
  test "bits_required over the 128-bit domain" do
    assert Bits.bits_required(0, 1 <<< 64) == 65
    assert Bits.bits_required(0, (1 <<< 128) - 1) == 128
    assert Bits.bits_required(-(1 <<< 127), (1 <<< 127) - 1) == 128
    assert Bits.bits_required(-(1 <<< 70), 1 <<< 70) == 72
  end

  test "ranges offset from zero cost the same as their width" do
    assert Bits.bits_required(-100, 100) == 8
    assert Bits.bits_required(100, 100) == 0
    assert Bits.bits_required(-2_147_483_648, 2_147_483_647) == 32
  end
end
