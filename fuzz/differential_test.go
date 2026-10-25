// Package fuzz tests the Elixir serialize port differentially against
// serialize.go (github.com/mas-bandwidth/serialize.go/v2, pinned in go.mod),
// the family's differential pattern for a language with no native
// coverage-guided fuzzer. From a logged seed it generates random programs, each
// a sequence of 1 to 24 operations drawn from every operation the wire format
// defines, ended by serialize_end as a packet reader must (STANDARD.md, end),
// and for each program:
//
//  1. serialize.go writes it and the Elixir port writes it (fuzz/driver.exs);
//     the bytes must be identical, and the Elixir measure stream must measure at
//     least the bits the Elixir writer wrote.
//  2. Each side reads the other's bytes back to the program's values (floats by
//     bit pattern; a compressed float by the value serialize.go decodes, since
//     quantization is lossy).
//  3. For 1 in 4 programs the bytes are mutated (a bit flip, a truncation, an
//     extension, or replaced by hostile random bytes), and both readers must
//     agree on whether they stop, on the index of the step that refused, on the
//     refusal reason as STANDARD.md spells it, and on every value decoded
//     before it.
//
// One BEAM start runs a batch of programs: all writes, then every clean read,
// then each mutated read. A failing program is written, replayable, to the
// -failures directory. -duration keeps generating rounds until it has run that
// long (the nightly run); without it one round runs (the CI smoke run).
//
// THE NEGATIVE CONTROL. -widen-int makes the Go writer and reader use int64
// ranges one bit wider than the Elixir side declares, so the bytes differ and
// the test must go red. CI runs it and requires the red.
//
// This is a functional test, never a unit test: it spawns the BEAM. Build the
// port first: MIX_ENV=test mix compile.
package fuzz

import (
	"bytes"
	"encoding/hex"
	"flag"
	"fmt"
	"math"
	"math/big"
	"math/rand/v2"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"time"
	"unicode/utf8"

	serialize "github.com/mas-bandwidth/serialize.go/v2"
)

var (
	widenIntRange = flag.Bool("widen-int", false, "negative control: the Go side widens int64 ranges by one bit, so the test must go red")
	seedFlag      = flag.Uint64("seed", 0, "generator seed; 0 means the fixed default seed")
	durationFlag  = flag.Duration("duration", 0, "keep running rounds until this much time has passed; 0 runs one round")
	programsFlag  = flag.Int("programs", 2000, "programs per round")
	failuresFlag  = flag.String("failures", "", "directory a failing program is written to, replayable by driver.exs")
)

const (
	defaultSeed = 0x5e71a112e0e11c12
	batchSize   = 500 // programs per BEAM start
	maxOps      = 24
)

var allKinds = []string{
	"bits", "bits64", "bool", "u8", "u16", "u32", "u64", "u128",
	"int", "int64", "i128", "fixed64", "fixed128", "intrel",
	"float", "double", "cfloat", "bytes", "str", "align", "object", "end",
}

type op struct {
	kind    string
	width   int
	lo, hi  int64
	valI    int64
	valU    uint64
	valF32  float32
	valF64  float64
	payload []byte
	bufSize int
	prev    int32

	ib, fb int

	cfMin, cfMax, cfRes uint32

	min128, max128, val128 serialize.Int128
	u128                   serialize.Uint128

	objU uint32
	objB bool
}

func f32bits(bits uint32) float32 { return math.Float32frombits(bits) }

var two128 = new(big.Int).Lsh(big.NewInt(1), 128)

func u128dec(x serialize.Uint128) string {
	b := new(big.Int).SetUint64(x.Hi)
	b.Lsh(b, 64)
	b.Or(b, new(big.Int).SetUint64(x.Lo))
	return b.String()
}

func i128dec(x serialize.Int128) string {
	b := new(big.Int).SetUint64(x.Hi)
	b.Lsh(b, 64)
	b.Or(b, new(big.Int).SetUint64(x.Lo))
	if x.IsNegative() {
		b.Sub(b, two128)
	}
	return b.String()
}

func dec(v int64) string   { return strconv.FormatInt(v, 10) }
func udec(v uint64) string { return strconv.FormatUint(v, 10) }

func hexOrDot(b []byte) string {
	if len(b) == 0 {
		return "."
	}
	return hex.EncodeToString(b)
}

func boolDigit(v bool) string {
	if v {
		return "1"
	}
	return "0"
}

// emit renders the op as a driver.exs command line: integers in decimal, floats
// as bit patterns, bytes as hex. The Elixir side always gets the declared ranges.
func (o op) emit() string {
	switch o.kind {
	case "bits", "bits64":
		return fmt.Sprintf("%s %d %d", o.kind, o.valU, o.width)
	case "bool":
		return "bool " + boolDigit(o.valU != 0)
	case "u8", "u16", "u32", "u64":
		return fmt.Sprintf("%s %d", o.kind, o.valU)
	case "u128":
		return "u128 " + u128dec(o.u128)
	case "int", "int64":
		return fmt.Sprintf("%s %d %d %d", o.kind, o.valI, o.lo, o.hi)
	case "i128":
		return fmt.Sprintf("i128 %s %s %s", i128dec(o.val128), i128dec(o.min128), i128dec(o.max128))
	case "fixed64":
		return fmt.Sprintf("fixed64 %d %d %d %d %d", o.valI, o.ib, o.fb, o.lo, o.hi)
	case "fixed128":
		return fmt.Sprintf("fixed128 %s %d %d %d %d", i128dec(o.val128), o.ib, o.fb, o.lo, o.hi)
	case "intrel":
		return fmt.Sprintf("intrel %d %d", o.prev, o.valI)
	case "float":
		return fmt.Sprintf("float %08x", math.Float32bits(o.valF32))
	case "double":
		return fmt.Sprintf("double %016x", math.Float64bits(o.valF64))
	case "cfloat":
		return fmt.Sprintf("cfloat %08x %08x %08x %08x", math.Float32bits(o.valF32), o.cfMin, o.cfMax, o.cfRes)
	case "bytes":
		return fmt.Sprintf("bytes %s %d", hexOrDot(o.payload), len(o.payload))
	case "str":
		return fmt.Sprintf("str %s %d", hexOrDot(o.payload), o.bufSize)
	case "align", "end":
		return o.kind
	case "object":
		return fmt.Sprintf("object %d %s", o.objU, boolDigit(o.objB))
	}
	panic("emit: unknown kind " + o.kind)
}

// fuzzObject is the object operation: a uint32 and a bool through SerializeObject.
type fuzzObject struct {
	u uint32
	b bool
}

func (o *fuzzObject) Serialize(s serialize.Stream) error {
	u := o.u
	if s.IsReading() {
		u = 0
	}
	if err := s.SerializeUint32(&u); err != nil {
		return err
	}
	o.u = u
	b := o.b
	if s.IsReading() {
		b = false
	}
	if err := s.SerializeBool(&b); err != nil {
		return err
	}
	o.b = b
	return nil
}

// int64Max is the upper bound the Go side uses for an int64 range: the declared
// one, or one bit wider under the negative control.
func int64Max(hi int64) int64 {
	if !*widenIntRange || hi < 0 || hi > (math.MaxInt64-1)/2 {
		return hi
	}
	return hi*2 + 1
}

func (o *op) write(w *serialize.WriteStream) {
	switch o.kind {
	case "bits":
		v := uint32(o.valU)
		_ = w.SerializeBits(&v, o.width)
	case "bits64":
		v := o.valU
		_ = w.SerializeBits64(&v, o.width)
	case "bool":
		v := o.valU != 0
		_ = w.SerializeBool(&v)
	case "u8":
		v := uint8(o.valU)
		_ = w.SerializeUint8(&v)
	case "u16":
		v := uint16(o.valU)
		_ = w.SerializeUint16(&v)
	case "u32":
		v := uint32(o.valU)
		_ = w.SerializeUint32(&v)
	case "u64":
		v := o.valU
		_ = w.SerializeUint64(&v)
	case "int":
		v := int32(o.valI)
		_ = w.SerializeInt(&v, int32(o.lo), int32(o.hi))
	case "int64":
		v := o.valI
		_ = w.SerializeInt64(&v, o.lo, int64Max(o.hi))
	case "u128":
		v := o.u128
		_ = w.SerializeUint128(&v)
	case "i128":
		v := o.val128
		_ = w.SerializeInt128(&v, o.min128, o.max128)
	case "fixed64":
		v := o.valI
		_ = w.SerializeFixed64(&v, o.ib, o.fb, o.lo, o.hi)
	case "fixed128":
		v := o.val128
		_ = w.SerializeFixed128(&v, o.ib, o.fb, o.lo, o.hi)
	case "intrel":
		v := int32(o.valI)
		_ = w.SerializeIntRelative(o.prev, &v)
	case "float":
		v := o.valF32
		_ = w.SerializeFloat32(&v)
	case "double":
		v := o.valF64
		_ = w.SerializeFloat64(&v)
	case "cfloat":
		v := o.valF32
		_ = w.SerializeCompressedFloat32(&v, f32bits(o.cfMin), f32bits(o.cfMax), f32bits(o.cfRes))
	case "bytes":
		_ = w.SerializeBytes(o.payload)
	case "str":
		v := string(o.payload)
		_ = w.SerializeString(&v, o.bufSize)
	case "align":
		_ = w.SerializeAlign()
	case "end":
		_ = w.SerializeEnd()
	case "object":
		_ = w.SerializeObject(&fuzzObject{u: o.objU, b: o.objB})
	default:
		panic("write: unknown kind " + o.kind)
	}
}

// read replays the op on a reader and returns its decoded value as a token, or
// false at the first refusal. Tokens are spelled exactly as driver.exs spells
// them.
func (o op) read(r *serialize.ReadStream) (bool, string) {
	switch o.kind {
	case "bits":
		var v uint32
		if r.SerializeBits(&v, o.width) != nil {
			return false, ""
		}
		return true, udec(uint64(v))
	case "bits64":
		var v uint64
		if r.SerializeBits64(&v, o.width) != nil {
			return false, ""
		}
		return true, udec(v)
	case "bool":
		var v bool
		if r.SerializeBool(&v) != nil {
			return false, ""
		}
		return true, boolDigit(v)
	case "u8":
		var v uint8
		if r.SerializeUint8(&v) != nil {
			return false, ""
		}
		return true, udec(uint64(v))
	case "u16":
		var v uint16
		if r.SerializeUint16(&v) != nil {
			return false, ""
		}
		return true, udec(uint64(v))
	case "u32":
		var v uint32
		if r.SerializeUint32(&v) != nil {
			return false, ""
		}
		return true, udec(uint64(v))
	case "u64":
		var v uint64
		if r.SerializeUint64(&v) != nil {
			return false, ""
		}
		return true, udec(v)
	case "int":
		var v int32
		if r.SerializeInt(&v, int32(o.lo), int32(o.hi)) != nil {
			return false, ""
		}
		return true, dec(int64(v))
	case "int64":
		var v int64
		if r.SerializeInt64(&v, o.lo, int64Max(o.hi)) != nil {
			return false, ""
		}
		return true, dec(v)
	case "u128":
		var v serialize.Uint128
		if r.SerializeUint128(&v) != nil {
			return false, ""
		}
		return true, u128dec(v)
	case "i128":
		var v serialize.Int128
		if r.SerializeInt128(&v, o.min128, o.max128) != nil {
			return false, ""
		}
		return true, i128dec(v)
	case "fixed64":
		var v int64
		if r.SerializeFixed64(&v, o.ib, o.fb, o.lo, o.hi) != nil {
			return false, ""
		}
		return true, dec(v)
	case "fixed128":
		var v serialize.Int128
		if r.SerializeFixed128(&v, o.ib, o.fb, o.lo, o.hi) != nil {
			return false, ""
		}
		return true, i128dec(v)
	case "intrel":
		var v int32
		if r.SerializeIntRelative(o.prev, &v) != nil {
			return false, ""
		}
		return true, dec(int64(v))
	case "float":
		var v float32
		if r.SerializeFloat32(&v) != nil {
			return false, ""
		}
		return true, fmt.Sprintf("%08x", math.Float32bits(v))
	case "double":
		var v float64
		if r.SerializeFloat64(&v) != nil {
			return false, ""
		}
		return true, fmt.Sprintf("%016x", math.Float64bits(v))
	case "cfloat":
		var v float32
		if r.SerializeCompressedFloat32(&v, f32bits(o.cfMin), f32bits(o.cfMax), f32bits(o.cfRes)) != nil {
			return false, ""
		}
		return true, fmt.Sprintf("%08x", math.Float32bits(v))
	case "bytes":
		buf := make([]byte, len(o.payload))
		if r.SerializeBytes(buf) != nil {
			return false, ""
		}
		return true, hexOrDot(buf)
	case "str":
		var v string
		if r.SerializeString(&v, o.bufSize) != nil {
			return false, ""
		}
		return true, hexOrDot([]byte(v))
	case "align":
		if r.SerializeAlign() != nil {
			return false, ""
		}
		return true, "-"
	case "end":
		if r.SerializeEnd() != nil {
			return false, ""
		}
		return true, "-"
	case "object":
		obj := fuzzObject{}
		if r.SerializeObject(&obj) != nil {
			return false, ""
		}
		return true, fmt.Sprintf("%d,%s", obj.u, boolDigit(obj.b))
	}
	panic("read: unknown kind " + o.kind)
}

// expectedToken is what a clean read of the op must return: the value written.
func expectedToken(o op) string {
	switch o.kind {
	case "bits", "bits64", "u8", "u16", "u32", "u64":
		return udec(o.valU)
	case "bool":
		return boolDigit(o.valU != 0)
	case "int", "int64", "intrel", "fixed64":
		return dec(o.valI)
	case "u128":
		return u128dec(o.u128)
	case "i128", "fixed128":
		return i128dec(o.val128)
	case "float", "cfloat":
		return fmt.Sprintf("%08x", math.Float32bits(o.valF32))
	case "double":
		return fmt.Sprintf("%016x", math.Float64bits(o.valF64))
	case "bytes", "str":
		return hexOrDot(o.payload)
	case "align", "end":
		return "-"
	case "object":
		return fmt.Sprintf("%d,%s", o.objU, boolDigit(o.objB))
	}
	panic("expectedToken: unknown kind " + o.kind)
}

type program struct {
	ops []op
}

type gen struct {
	rng *rand.Rand
}

func (g *gen) rangeI(lo, hi int64) int64 {
	if lo >= hi {
		return lo
	}
	span := uint64(hi) - uint64(lo)
	if span == math.MaxUint64 {
		return int64(g.rng.Uint64())
	}
	return int64(uint64(lo) + g.rng.Uint64N(span+1))
}

func mask(width int) uint64 {
	if width >= 64 {
		return math.MaxUint64
	}
	return (uint64(1) << width) - 1
}

// storageWidth picks one of the fixed point storage widths at least min wide.
func (g *gen) storageWidth(min int) int {
	widths := []int{8, 16, 32, 64}
	for {
		w := widths[g.rng.IntN(len(widths))]
		if w >= min {
			return w
		}
	}
}

// utf8Payload is well-formed UTF-8 with no zero byte, shorter than bufSize bytes.
func (g *gen) utf8Payload(bufSize int) []byte {
	runes := []rune{'a', 'Z', '~', 0x7f, 0xe9, 0x3a9, 0x20ac, 0xfeff, 0x1d11e, 0x10ffff}
	limit := int(g.rangeI(0, int64(bufSize)-1))
	var out []byte
	for {
		var r rune
		if g.rng.IntN(2) == 0 {
			r = rune(g.rangeI(1, 0x7f))
		} else {
			r = runes[g.rng.IntN(len(runes))]
		}
		if len(out)+utf8.RuneLen(r) > limit {
			return out
		}
		out = utf8.AppendRune(out, r)
	}
}

func (g *gen) op() op {
	var o op
	rng := g.rng
	switch rng.IntN(21) {
	case 0:
		o.kind = "bits"
		o.width = int(g.rangeI(1, 32))
		o.valU = rng.Uint64() & mask(o.width)
	case 1:
		o.kind = "bits64"
		o.width = int(g.rangeI(1, 64))
		o.valU = rng.Uint64() & mask(o.width)
	case 2:
		o.kind = "bool"
		o.valU = uint64(rng.IntN(2))
	case 3:
		o.kind = "u8"
		o.valU = rng.Uint64() & 0xff
	case 4:
		o.kind = "u16"
		o.valU = rng.Uint64() & 0xffff
	case 5:
		o.kind = "u32"
		o.valU = rng.Uint64() & 0xffffffff
	case 6:
		o.kind = "u64"
		o.valU = rng.Uint64()
	case 7: // int32 ranged, with degenerate and edge ranges
		o.kind = "int"
		switch rng.IntN(4) {
		case 0:
			o.lo = g.rangeI(-100000, 100000)
			o.hi = o.lo + g.rangeI(0, 200000)
		case 1:
			o.lo = int64(rng.Int32())
			o.hi = o.lo
		case 2:
			o.lo = math.MinInt32
			o.hi = math.MaxInt32
		default:
			o.lo = math.MinInt32
			o.hi = math.MinInt32 + g.rangeI(0, 1<<20)
		}
		o.valI = g.rangeI(o.lo, o.hi)
	case 8: // int64 ranged, with degenerate and edge ranges
		o.kind = "int64"
		switch rng.IntN(6) {
		case 0:
			o.lo = g.rangeI(-1<<40, 1<<40)
			o.hi = o.lo + g.rangeI(0, 1<<44)
		case 1:
			o.lo = int64(rng.Uint64())
			o.hi = o.lo
		case 2:
			o.lo = math.MinInt64
			o.hi = o.lo + g.rangeI(0, 1<<20)
		case 3:
			o.hi = math.MaxInt64
			o.lo = o.hi - g.rangeI(0, 1<<20)
		case 4:
			o.lo = math.MinInt64
			o.hi = math.MaxInt64
		default:
			o.lo = math.MinInt32
			o.hi = math.MaxInt32
		}
		o.valI = g.rangeI(o.lo, o.hi)
	case 9:
		o.kind = "u128"
		o.u128 = serialize.Uint128{Lo: rng.Uint64(), Hi: rng.Uint64()}
	case 10: // int128 ranged: small, wide positive, full 127-bit, negative, degenerate
		o.kind = "i128"
		switch rng.IntN(5) {
		case 0:
			lo := g.rangeI(-1<<40, 1<<40)
			hi := lo + g.rangeI(0, 1<<40)
			o.min128 = serialize.Int128From64(lo)
			o.max128 = serialize.Int128From64(hi)
			o.val128 = serialize.Int128From64(g.rangeI(lo, hi))
		case 1:
			o.min128 = serialize.Int128{Lo: rng.Uint64(), Hi: rng.Uint64() & 0x3fffffffffffffff}
			span := g.rangeI(0, 1<<32)
			o.max128 = o.min128.Add(serialize.Int128From64(span))
			o.val128 = o.min128.Add(serialize.Int128From64(g.rangeI(0, span)))
		case 2:
			o.min128 = serialize.Int128{}
			o.max128 = serialize.Int128{Lo: math.MaxUint64, Hi: math.MaxInt64}
			o.val128 = serialize.Int128{Lo: rng.Uint64(), Hi: rng.Uint64() & math.MaxInt64}
		case 3:
			o.min128 = serialize.Int128{Lo: rng.Uint64(), Hi: rng.Uint64() | 0x8000000000000000}
			span := g.rangeI(0, 1<<40)
			o.max128 = o.min128.Add(serialize.Int128From64(span))
			o.val128 = o.min128.Add(serialize.Int128From64(g.rangeI(0, span)))
		default:
			v := serialize.Int128{Lo: rng.Uint64(), Hi: rng.Uint64()}
			o.min128, o.max128, o.val128 = v, v, v
		}
	case 11: // fixed64: integerBits + fractionBits fill a storage width (8, 16, 32 or 64)
		o.kind = "fixed64"
		switch rng.IntN(5) {
		case 0:
			w := g.storageWidth(8)
			o.fb = int(g.rangeI(0, int64(min(16, w-8))))
			o.ib = w - o.fb
			o.lo = g.rangeI(-100, 0)
			o.hi = o.lo + g.rangeI(0, 100)
		case 1:
			o.ib, o.fb = 32, 0
			o.lo, o.hi = math.MinInt32, math.MaxInt32
		case 2:
			o.ib, o.fb = 16, 16
			o.lo, o.hi = -(1 << 15), (1<<15)-1
		case 3:
			o.ib, o.fb = 64, 0
			o.lo, o.hi = math.MinInt64, math.MaxInt64
		default:
			w := g.storageWidth(16)
			o.fb = int(g.rangeI(0, int64(min(8, w-8))))
			o.ib = w - o.fb
			o.lo = g.rangeI(-100, 100)
			o.hi = o.lo
		}
		o.valI = g.rangeI(o.lo<<o.fb, o.hi<<o.fb)
	case 12: // fixed128: integerBits + fractionBits == 128
		o.kind = "fixed128"
		o.fb = int(g.rangeI(1, 48))
		o.ib = 128 - o.fb
		o.lo = g.rangeI(-1<<20, 0)
		o.hi = o.lo + g.rangeI(0, 1<<20)
		if rng.IntN(4) == 0 {
			o.hi = o.lo
		}
		lo128 := serialize.Int128From64(o.lo).Lsh(uint(o.fb))
		span := serialize.Int128From64(o.hi - o.lo).Lsh(uint(o.fb))
		off := serialize.Int128{Lo: rng.Uint64(), Hi: rng.Uint64() & 0xffffffffffff}
		if !span.IsNegative() && span.Cmp(serialize.Int128{}) > 0 {
			off = off.Uint128().Mod(span.Add(serialize.Int128From64(1)).Uint128()).Int128()
		} else {
			off = serialize.Int128{}
		}
		o.val128 = lo128.Add(off)
	case 13: // int_relative, every tier
		o.kind = "intrel"
		switch rng.IntN(4) {
		case 0:
			o.prev = 0
			o.valI = 1
		case 1:
			o.prev = math.MaxInt32 - 1
			o.valI = math.MaxInt32
		case 2:
			o.prev = int32(g.rangeI(0, math.MaxInt32-70000))
			o.valI = int64(o.prev) + g.rangeI(1, 69914)
		default:
			o.prev = int32(g.rangeI(0, math.MaxInt32-1))
			o.valI = g.rangeI(int64(o.prev)+1, math.MaxInt32)
		}
	case 14: // float32: finite patterns only (format 2.0), the edges included
		o.kind = "float"
		bits := rng.Uint32()
		switch rng.IntN(8) {
		case 0:
			bits &= 0x807fffff
		case 1:
			bits = (bits & 0x807fffff) | 0x7f000000
		}
		if bits&0x7f800000 == 0x7f800000 {
			bits &^= 0x00800000
		}
		o.valF32 = math.Float32frombits(bits)
	case 15: // double: finite patterns only (format 2.0), the edges included
		o.kind = "double"
		bits := rng.Uint64()
		switch rng.IntN(8) {
		case 0:
			bits &= 0x800fffffffffffff
		case 1:
			bits = (bits & 0x800fffffffffffff) | 0x7fe0000000000000
		}
		if bits&0x7ff0000000000000 == 0x7ff0000000000000 {
			bits &^= 0x0010000000000000
		}
		o.valF64 = math.Float64frombits(bits)
	case 16: // compressed float32, exactly representable integers at resolution 1
		o.kind = "cfloat"
		lo := int32(g.rangeI(-1000, -1))
		hi := int32(g.rangeI(1, 1000))
		o.cfMin = math.Float32bits(float32(lo))
		o.cfMax = math.Float32bits(float32(hi))
		o.cfRes = math.Float32bits(1)
		o.valF32 = float32(g.rangeI(int64(lo), int64(hi)))
	case 17:
		o.kind = "bytes"
		o.payload = make([]byte, g.rangeI(0, 64))
		for i := range o.payload {
			o.payload[i] = byte(rng.Uint32())
		}
	case 18:
		o.kind = "str"
		o.bufSize = int(g.rangeI(1, 256))
		o.payload = g.utf8Payload(o.bufSize)
	case 19:
		o.kind = "align"
	default:
		o.kind = "object"
		o.objU = rng.Uint32()
		o.objB = rng.IntN(2) == 1
	}
	return o
}

func (g *gen) program() program {
	n := int(g.rangeI(1, maxOps))
	var p program
	for i := 0; i < n; i++ {
		p.ops = append(p.ops, g.op())
	}
	// a packet is one object and its end (STANDARD.md, end)
	p.ops = append(p.ops, op{kind: "end"})
	return p
}

func (g *gen) mutate(b []byte) []byte {
	switch g.rng.IntN(4) {
	case 0: // bit flip
		if len(b) == 0 {
			return []byte{byte(1 << g.rng.IntN(8))}
		}
		cp := append([]byte(nil), b...)
		cp[g.rng.IntN(len(cp))] ^= 1 << g.rng.IntN(8)
		return cp
	case 1: // truncation
		if len(b) == 0 {
			return b
		}
		return b[:g.rng.IntN(len(b))]
	case 2: // extension
		return append(append([]byte(nil), b...), byte(g.rng.IntN(256)))
	default: // hostile: random bytes of a random length
		cp := make([]byte, g.rng.IntN(len(b)+9))
		for i := range cp {
			cp[i] = byte(g.rng.Uint32())
		}
		return cp
	}
}

func writeGo(p program) []byte {
	w := serialize.NewWriteStream(make([]byte, 1<<16))
	for i := range p.ops {
		p.ops[i].write(w)
	}
	w.Flush()
	if err := w.Err(); err != nil {
		panic(fmt.Sprintf("go writer refused a generated program: %v", err))
	}
	return append([]byte(nil), w.Data()...)
}

type readResult struct {
	n      int
	reason string // the first refusal's reason as STANDARD.md spells it, "ok" if none
	tokens []string
}

func readGo(p program, data []byte) readResult {
	r := serialize.NewReadStream(data)
	var res readResult
	for _, o := range p.ops {
		ok, tok := o.read(r)
		if !ok {
			break
		}
		res.tokens = append(res.tokens, tok)
	}
	res.n = len(res.tokens)
	res.reason = "ok"
	if err := r.Err(); err != nil {
		refusal, isRefusal := err.(serialize.Refusal)
		if !isRefusal {
			panic(fmt.Sprintf("go reader latched a non-refusal error %v", err))
		}
		res.reason = refusal.String()
	}
	return res
}

type writeResult struct {
	data     []byte
	bits     int
	measured int
}

func repoRoot(t *testing.T) string {
	wd, err := os.Getwd()
	if err != nil {
		t.Fatal(err)
	}
	return filepath.Dir(wd)
}

func ebinDir(t *testing.T) string {
	if dir := os.Getenv("SERIALIZE_EBIN"); dir != "" {
		return dir
	}
	dir := filepath.Join(repoRoot(t), "_build", "test", "lib", "serialize", "ebin")
	if _, err := os.Stat(filepath.Join(dir, "Elixir.Serialize.beam")); err != nil {
		t.Fatalf("no compiled port at %s: run MIX_ENV=test mix compile first (or set SERIALIZE_EBIN)", dir)
	}
	return dir
}

// runDriver runs one batch file through one BEAM start. The driver must print
// nothing to stderr: a compiler warning in driver.exs fails the run.
func runDriver(t *testing.T, batchFile string) []string {
	elixir := os.Getenv("ELIXIR")
	if elixir == "" {
		elixir = "elixir"
	}
	cmd := exec.Command(elixir, "-pa", ebinDir(t), filepath.Join(repoRoot(t), "fuzz", "driver.exs"), batchFile)
	var stderr bytes.Buffer
	cmd.Stderr = &stderr
	out, err := cmd.Output()
	if err != nil {
		t.Fatalf("driver failed: %v\nbatch: %s\nstderr:\n%s", err, batchFile, stderr.String())
	}
	if stderr.Len() != 0 {
		t.Fatalf("driver wrote to stderr (zero warnings):\n%s", stderr.String())
	}
	return strings.Split(strings.TrimSuffix(string(out), "\n"), "\n")
}

func parseWrite(t *testing.T, line string) writeResult {
	f := strings.Fields(line)
	if len(f) != 4 || f[0] != "HEX" {
		t.Fatalf("expected HEX <hex> <bits> <measured>, got %q", line)
	}
	var res writeResult
	if f[1] != "." {
		b, err := hex.DecodeString(f[1])
		if err != nil {
			t.Fatalf("bad HEX line %q: %v", line, err)
		}
		res.data = b
	}
	var err1, err2 error
	res.bits, err1 = strconv.Atoi(f[2])
	res.measured, err2 = strconv.Atoi(f[3])
	if err1 != nil || err2 != nil {
		t.Fatalf("bad HEX counts in %q", line)
	}
	return res
}

func parseRead(t *testing.T, line string) readResult {
	f := strings.Fields(line)
	if len(f) < 3 || f[0] != "READ" {
		t.Fatalf("expected READ <n> <reason> <tokens>, got %q", line)
	}
	n, err := strconv.Atoi(f[1])
	if err != nil {
		t.Fatalf("bad READ count in %q: %v", line, err)
	}
	if len(f[3:]) != n {
		t.Fatalf("READ line %q reports %d but carries %d tokens", line, n, len(f[3:]))
	}
	return readResult{n: n, reason: f[2], tokens: f[3:]}
}

func emitProgram(sb *strings.Builder, header string, p program) {
	sb.WriteString(header)
	sb.WriteString("\n")
	for _, o := range p.ops {
		sb.WriteString(o.emit())
		sb.WriteString("\n")
	}
	sb.WriteString("END\n")
}

type harness struct {
	t     *testing.T
	seed  uint64
	round int
	tmp   string
}

// fail records the failing program, replayable by driver.exs, in the -failures
// directory, then fails the test.
func (h *harness) fail(i int, p program, inputs [][]byte, format string, args ...any) {
	h.t.Helper()
	msg := fmt.Sprintf(format, args...)
	var sb strings.Builder
	emitProgram(&sb, "W", p)
	for _, in := range inputs {
		emitProgram(&sb, "R "+hexOrDot(in), p)
	}
	if *failuresFlag != "" {
		if err := os.MkdirAll(*failuresFlag, 0o755); err == nil {
			base := filepath.Join(*failuresFlag, fmt.Sprintf("failure-seed%d-round%d-program%d", h.seed, h.round, i))
			_ = os.WriteFile(base+".batch", []byte(sb.String()), 0o644)
			_ = os.WriteFile(base+".txt", []byte(fmt.Sprintf("seed %d round %d program %d\n%s\n", h.seed, h.round, i, msg)), 0o644)
		}
	}
	h.t.Fatalf("seed %d round %d program %d: %s\nreplay (elixir -pa _build/test/lib/serialize/ebin fuzz/driver.exs <file>):\n%s",
		h.seed, h.round, i, msg, sb.String())
}

func equalStrings(a, b []string) bool {
	if len(a) != len(b) {
		return false
	}
	for i := range a {
		if a[i] != b[i] {
			return false
		}
	}
	return true
}

// runRound generates n programs and holds both sides to every check. It returns
// the number of mutated programs.
func (h *harness) runRound(g *gen, n int, seen map[string]bool) int {
	t := h.t
	programs := make([]program, n)
	goBytes := make([][]byte, n)
	mutated := make([][]byte, n)
	mutatedCount := 0
	for i := range programs {
		programs[i] = g.program()
		for _, o := range programs[i].ops {
			seen[o.kind] = true
		}
		goBytes[i] = writeGo(programs[i])
		if g.rng.IntN(4) == 0 {
			mutated[i] = g.mutate(goBytes[i])
			mutatedCount++
		}
	}

	exWrite := make([]writeResult, n)
	exRead := make([]readResult, n)
	exMutRead := make([]readResult, n)
	for start := 0; start < n; start += batchSize {
		end := min(start+batchSize, n)
		var sb strings.Builder
		for i := start; i < end; i++ {
			emitProgram(&sb, "W", programs[i])
		}
		for i := start; i < end; i++ {
			emitProgram(&sb, "R "+hexOrDot(goBytes[i]), programs[i])
			if mutated[i] != nil {
				emitProgram(&sb, "R "+hexOrDot(mutated[i]), programs[i])
			}
		}
		batchFile := filepath.Join(h.tmp, fmt.Sprintf("round%d-batch%d.txt", h.round, start/batchSize))
		if err := os.WriteFile(batchFile, []byte(sb.String()), 0o644); err != nil {
			t.Fatal(err)
		}
		lines := runDriver(t, batchFile)
		pos := 0
		next := func() string {
			if pos >= len(lines) {
				t.Fatalf("batch %s: driver printed only %d result lines", batchFile, len(lines))
			}
			pos++
			return lines[pos-1]
		}
		for i := start; i < end; i++ {
			exWrite[i] = parseWrite(t, next())
		}
		for i := start; i < end; i++ {
			exRead[i] = parseRead(t, next())
			if mutated[i] != nil {
				exMutRead[i] = parseRead(t, next())
			}
		}
		if pos != len(lines) {
			t.Fatalf("batch %s: consumed %d result lines, driver printed %d", batchFile, pos, len(lines))
		}
		_ = os.Remove(batchFile)
	}

	for i := 0; i < n; i++ {
		p := programs[i]
		// (1) identical writers, and a measure that never under-measures
		if !bytes.Equal(goBytes[i], exWrite[i].data) {
			h.fail(i, p, nil, "bytes differ\ngo:     %x\nelixir: %x", goBytes[i], exWrite[i].data)
		}
		if exWrite[i].measured < exWrite[i].bits {
			h.fail(i, p, nil, "elixir measure %d bits under-measures the %d bits written", exWrite[i].measured, exWrite[i].bits)
		}
		// (2) cross reads: go reads elixir's bytes, elixir reads go's
		goRes := readGo(p, exWrite[i].data)
		if goRes.reason != "ok" || goRes.n != len(p.ops) {
			h.fail(i, p, nil, "go refused elixir's bytes at step %d (%s)", goRes.n, goRes.reason)
		}
		for j, o := range p.ops {
			if o.kind != "cfloat" && goRes.tokens[j] != expectedToken(o) {
				h.fail(i, p, nil, "go decoded step %d (%s) as %s, wrote %s", j, o.kind, goRes.tokens[j], expectedToken(o))
			}
		}
		if exRead[i].reason != "ok" || exRead[i].n != len(p.ops) {
			h.fail(i, p, [][]byte{goBytes[i]}, "elixir refused go's bytes at step %d (%s)", exRead[i].n, exRead[i].reason)
		}
		if !equalStrings(exRead[i].tokens, goRes.tokens) {
			h.fail(i, p, [][]byte{goBytes[i]}, "decoded values differ\ngo:     %q\nelixir: %q", goRes.tokens, exRead[i].tokens)
		}
		// (3) mutation agreement: whether, where, why, and the values before it
		if mutated[i] != nil {
			goMut := readGo(p, mutated[i])
			exMut := exMutRead[i]
			if goMut.n != exMut.n || goMut.reason != exMut.reason || !equalStrings(goMut.tokens, exMut.tokens) {
				h.fail(i, p, [][]byte{mutated[i]},
					"mutation disagreement on %x (from %x)\ngo:     stopped at %d (%s) %q\nelixir: stopped at %d (%s) %q",
					mutated[i], goBytes[i], goMut.n, goMut.reason, goMut.tokens, exMut.n, exMut.reason, exMut.tokens)
			}
		}
	}
	return mutatedCount
}

func TestDifferentialAgainstSerializeGo(t *testing.T) {
	seed := *seedFlag
	if seed == 0 {
		seed = defaultSeed
	}
	t.Logf("seed %d (rerun with -seed %d)", seed, seed)
	fmt.Printf("fuzz: seed %d\n", seed)

	g := &gen{rng: rand.New(rand.NewPCG(seed, seed^0x9e3779b97f4a7c15))}
	h := &harness{t: t, seed: seed, tmp: t.TempDir()}
	seen := map[string]bool{}
	deadline := time.Now().Add(*durationFlag)
	total, mutatedTotal := 0, 0
	for {
		mutatedTotal += h.runRound(g, *programsFlag, seen)
		total += *programsFlag
		h.round++
		if !time.Now().Before(deadline) {
			break
		}
	}
	for _, kind := range allKinds {
		if !seen[kind] {
			t.Fatalf("generated programs never exercised %s", kind)
		}
	}
	t.Logf("ok  seed %d: %d rounds, %d programs, %d mutated, %d operation kinds", seed, h.round, total, mutatedTotal, len(seen))
}
