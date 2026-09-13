// Sprint: #155; Story: S155.10; Story-ID: 67bdd9fae2b3
//
// Insertion-ordered JSON with Ruby `JSON.generate` / `JSON.parse` semantics.
//
// The evidence contract is byte-exact: every record's `evidence_sha256` is the
// SHA-256 of the record serialized WITHOUT that key, and the root digest chains
// those hashes. The Ruby producer serialized Hashes in insertion order, wrote
// Floats with Float#to_s, and escaped only `"`, `\` and C0 controls. The
// validators re-serialize parsed records the same way, so a Go reader has to
// preserve key order and number spelling exactly; encoding/json (sorted map
// keys, HTML escaping, %g floats) cannot be used for anything that is hashed.
package main

import (
	"bytes"
	"fmt"
	"math"
	"math/big"
	"sort"
	"strconv"
	"strings"
	"unicode/utf16"
	"unicode/utf8"
)

// Object is an insertion-ordered string-keyed map (a Ruby Hash).
type Object struct {
	keys   []string
	values map[string]any
}

func NewObject() *Object { return &Object{values: map[string]any{}} }

// Obj builds an ordered object from alternating key/value pairs.
func Obj(pairs ...any) *Object {
	o := NewObject()
	for i := 0; i+1 < len(pairs); i += 2 {
		o.Set(pairs[i].(string), pairs[i+1])
	}
	return o
}

func (o *Object) Keys() []string { return append([]string(nil), o.keys...) }
func (o *Object) Len() int       { return len(o.keys) }
func (o *Object) Has(key string) bool {
	_, ok := o.values[key]
	return ok
}
func (o *Object) Get(key string) any { return o.values[key] }

// Set assigns; an existing key keeps its position, a new key is appended.
func (o *Object) Set(key string, value any) {
	if _, ok := o.values[key]; !ok {
		o.keys = append(o.keys, key)
	}
	o.values[key] = value
}

func (o *Object) Delete(key string) {
	if _, ok := o.values[key]; !ok {
		return
	}
	delete(o.values, key)
	for i, k := range o.keys {
		if k == key {
			o.keys = append(o.keys[:i:i], o.keys[i+1:]...)
			break
		}
	}
}

// Compact drops nil-valued keys (Hash#compact).
func (o *Object) Compact() *Object {
	out := NewObject()
	for _, k := range o.keys {
		if o.values[k] != nil {
			out.Set(k, o.values[k])
		}
	}
	return out
}

// Without returns a shallow copy lacking the given keys (Hash#reject by key).
func (o *Object) Without(keys ...string) *Object {
	out := NewObject()
	for _, k := range o.keys {
		skip := false
		for _, x := range keys {
			if x == k {
				skip = true
			}
		}
		if !skip {
			out.Set(k, o.values[k])
		}
	}
	return out
}

// Merge assigns every pair of other into o (Hash#merge!).
func (o *Object) Merge(other *Object) *Object {
	for _, k := range other.keys {
		o.Set(k, other.values[k])
	}
	return o
}

func (o *Object) Str(key string) string {
	s, _ := o.values[key].(string)
	return s
}

func (o *Object) Bool(key string) bool {
	b, _ := o.values[key].(bool)
	return b
}

func (o *Object) Obj(key string) *Object {
	v, _ := o.values[key].(*Object)
	return v
}

func (o *Object) Arr(key string) []any {
	v, _ := o.values[key].([]any)
	return v
}

// Int returns the integer value and whether the key held an integral Number.
func (o *Object) Int(key string) (int64, bool) {
	n, ok := o.values[key].(Number)
	if !ok || n.Float {
		return 0, false
	}
	return n.Int, true
}

// Number is a JSON number that remembers whether Ruby would have parsed it as
// an Integer or a Float, so it re-serializes the way Ruby wrote it.
type Number struct {
	Float bool
	Int   int64
	Big   string // decimal digits when the integer does not fit int64
	F     float64
}

func Int(i int64) Number   { return Number{Int: i} }
func Flt(f float64) Number { return Number{Float: true, F: f} }
func (n Number) String() string {
	if n.Float {
		return rubyFloat(n.F)
	}
	if n.Big != "" {
		return n.Big
	}
	return strconv.FormatInt(n.Int, 10)
}

// AsFloat returns the numeric value as a float64 (Ruby Numeric coercion).
func (n Number) AsFloat() float64 {
	if n.Float {
		return n.F
	}
	if n.Big != "" {
		f, _ := new(big.Float).SetString(n.Big)
		v, _ := f.Float64()
		return v
	}
	return float64(n.Int)
}

// numEqual compares two JSON values as Ruby would compare Numerics (1 == 1.0).
func numEqual(a, b any) bool {
	x, ok1 := a.(Number)
	y, ok2 := b.(Number)
	if !ok1 || !ok2 {
		return false
	}
	if !x.Float && !y.Float {
		return x.String() == y.String()
	}
	return x.AsFloat() == y.AsFloat()
}

// rubyFloat renders a float64 exactly as Ruby's Float#to_s does: shortest
// round-trip digits, fixed notation for 1e-4 <= |x| < 1e16, otherwise
// "d.ddde+XX" with a signed two-digit-minimum exponent.
func rubyFloat(f float64) string {
	if math.IsNaN(f) {
		return "NaN"
	}
	if math.IsInf(f, 1) {
		return "Infinity"
	}
	if math.IsInf(f, -1) {
		return "-Infinity"
	}
	if f == 0 {
		if math.Signbit(f) {
			return "-0.0"
		}
		return "0.0"
	}
	s := strconv.FormatFloat(f, 'e', -1, 64)
	neg := false
	if s[0] == '-' {
		neg = true
		s = s[1:]
	}
	epos := strings.IndexByte(s, 'e')
	mant, expo := s[:epos], s[epos+1:]
	digits := strings.Replace(mant, ".", "", 1)
	e, _ := strconv.Atoi(expo)
	decpt := e + 1
	var out string
	switch {
	case decpt > 0 && decpt <= 16:
		if len(digits) <= decpt {
			out = digits + strings.Repeat("0", decpt-len(digits)) + ".0"
		} else {
			out = digits[:decpt] + "." + digits[decpt:]
		}
	case decpt > -4 && decpt <= 0:
		out = "0." + strings.Repeat("0", -decpt) + digits
	default:
		frac := digits[1:]
		if frac == "" {
			frac = "0"
		}
		out = digits[:1] + "." + frac + fmt.Sprintf("e%+03d", decpt-1)
	}
	if neg {
		return "-" + out
	}
	return out
}

// Generate serializes like Ruby's JSON.generate: no whitespace, insertion
// order, Float#to_s numbers, and only `"`, `\` and C0 controls escaped.
func Generate(v any) string {
	var b bytes.Buffer
	generate(&b, v)
	return b.String()
}

func generate(b *bytes.Buffer, v any) {
	switch x := v.(type) {
	case nil:
		b.WriteString("null")
	case bool:
		if x {
			b.WriteString("true")
		} else {
			b.WriteString("false")
		}
	case string:
		writeRubyString(b, x)
	case Number:
		b.WriteString(x.String())
	case int:
		b.WriteString(strconv.Itoa(x))
	case int64:
		b.WriteString(strconv.FormatInt(x, 10))
	case uint64:
		b.WriteString(strconv.FormatUint(x, 10))
	case float64:
		b.WriteString(rubyFloat(x))
	case []string:
		b.WriteByte('[')
		for i, s := range x {
			if i > 0 {
				b.WriteByte(',')
			}
			writeRubyString(b, s)
		}
		b.WriteByte(']')
	case []any:
		b.WriteByte('[')
		for i, e := range x {
			if i > 0 {
				b.WriteByte(',')
			}
			generate(b, e)
		}
		b.WriteByte(']')
	case *Object:
		b.WriteByte('{')
		for i, k := range x.keys {
			if i > 0 {
				b.WriteByte(',')
			}
			writeRubyString(b, k)
			b.WriteByte(':')
			generate(b, x.values[k])
		}
		b.WriteByte('}')
	default:
		panic(fmt.Sprintf("jsonx: unsupported value %T", v))
	}
}

func writeRubyString(b *bytes.Buffer, s string) {
	const hexdig = "0123456789abcdef"
	b.WriteByte('"')
	for i := 0; i < len(s); i++ {
		c := s[i]
		switch c {
		case '"':
			b.WriteString(`\"`)
		case '\\':
			b.WriteString(`\\`)
		case '\b':
			b.WriteString(`\b`)
		case '\f':
			b.WriteString(`\f`)
		case '\n':
			b.WriteString(`\n`)
		case '\r':
			b.WriteString(`\r`)
		case '\t':
			b.WriteString(`\t`)
		default:
			if c < 0x20 {
				b.WriteString(`\u00`)
				b.WriteByte(hexdig[c>>4])
				b.WriteByte(hexdig[c&0xf])
			} else {
				b.WriteByte(c)
			}
		}
	}
	b.WriteByte('"')
}

// Canonical serializes with recursively sorted object keys (Corpus.canonical).
func Canonical(v any) string { return Generate(sortKeys(v)) }

func sortKeys(v any) any {
	switch x := v.(type) {
	case *Object:
		keys := x.Keys()
		sort.Strings(keys)
		out := NewObject()
		for _, k := range keys {
			out.Set(k, sortKeys(x.values[k]))
		}
		return out
	case []any:
		out := make([]any, len(x))
		for i, e := range x {
			out[i] = sortKeys(e)
		}
		return out
	default:
		return v
	}
}

// Pretty serializes like Ruby's JSON.pretty_generate (two-space indent, ": "
// after keys, empty containers as [] / {}). Only used for helper manifests.
func Pretty(v any) string {
	var b bytes.Buffer
	pretty(&b, v, "")
	return b.String()
}

func pretty(b *bytes.Buffer, v any, indent string) {
	switch x := v.(type) {
	case []any:
		if len(x) == 0 {
			b.WriteString("[\n\n" + indent + "]") // JSON.pretty_generate renders an empty Array this way
			return
		}
		b.WriteString("[\n")
		for i, e := range x {
			b.WriteString(indent + "  ")
			pretty(b, e, indent+"  ")
			if i+1 < len(x) {
				b.WriteByte(',')
			}
			b.WriteByte('\n')
		}
		b.WriteString(indent + "]")
	case *Object:
		if x.Len() == 0 {
			b.WriteString("{}")
			return
		}
		b.WriteString("{\n")
		for i, k := range x.keys {
			b.WriteString(indent + "  ")
			writeRubyString(b, k)
			b.WriteString(": ")
			pretty(b, x.values[k], indent+"  ")
			if i+1 < len(x.keys) {
				b.WriteByte(',')
			}
			b.WriteByte('\n')
		}
		b.WriteString(indent + "}")
	default:
		generate(b, v)
	}
}

// Parse reads one JSON document with Ruby JSON.parse semantics: objects keep
// insertion order (a duplicate key keeps its first position, last value),
// integers stay Integers and anything with a fraction or exponent is a Float.
func Parse(data []byte) (any, error) {
	p := &parser{data: data}
	p.skipSpace()
	v, err := p.value()
	if err != nil {
		return nil, err
	}
	p.skipSpace()
	if p.pos != len(p.data) {
		return nil, fmt.Errorf("unexpected token at %d", p.pos)
	}
	return v, nil
}

// ParseObject is Parse restricted to a top-level object.
func ParseObject(data []byte) (*Object, error) {
	v, err := Parse(data)
	if err != nil {
		return nil, err
	}
	o, ok := v.(*Object)
	if !ok {
		return nil, fmt.Errorf("not a JSON object")
	}
	return o, nil
}

type parser struct {
	data []byte
	pos  int
}

func (p *parser) skipSpace() {
	for p.pos < len(p.data) {
		switch p.data[p.pos] {
		case ' ', '\t', '\n', '\r':
			p.pos++
		default:
			return
		}
	}
}

func (p *parser) value() (any, error) {
	if p.pos >= len(p.data) {
		return nil, fmt.Errorf("unexpected end of input")
	}
	switch c := p.data[p.pos]; {
	case c == '{':
		return p.object()
	case c == '[':
		return p.array()
	case c == '"':
		return p.str()
	case c == 't':
		return p.literal("true", true)
	case c == 'f':
		return p.literal("false", false)
	case c == 'n':
		return p.literal("null", nil)
	case c == '-' || (c >= '0' && c <= '9'):
		return p.number()
	}
	return nil, fmt.Errorf("unexpected character %q at %d", p.data[p.pos], p.pos)
}

func (p *parser) literal(word string, v any) (any, error) {
	if !bytes.HasPrefix(p.data[p.pos:], []byte(word)) {
		return nil, fmt.Errorf("unexpected token at %d", p.pos)
	}
	p.pos += len(word)
	return v, nil
}

func (p *parser) object() (any, error) {
	o := NewObject()
	p.pos++
	p.skipSpace()
	if p.pos < len(p.data) && p.data[p.pos] == '}' {
		p.pos++
		return o, nil
	}
	for {
		p.skipSpace()
		if p.pos >= len(p.data) || p.data[p.pos] != '"' {
			return nil, fmt.Errorf("expected object key at %d", p.pos)
		}
		k, err := p.str()
		if err != nil {
			return nil, err
		}
		p.skipSpace()
		if p.pos >= len(p.data) || p.data[p.pos] != ':' {
			return nil, fmt.Errorf("expected ':' at %d", p.pos)
		}
		p.pos++
		p.skipSpace()
		v, err := p.value()
		if err != nil {
			return nil, err
		}
		o.Set(k, v)
		p.skipSpace()
		if p.pos >= len(p.data) {
			return nil, fmt.Errorf("unexpected end of object")
		}
		if p.data[p.pos] == ',' {
			p.pos++
			continue
		}
		if p.data[p.pos] == '}' {
			p.pos++
			return o, nil
		}
		return nil, fmt.Errorf("expected ',' or '}' at %d", p.pos)
	}
}

func (p *parser) array() (any, error) {
	out := []any{}
	p.pos++
	p.skipSpace()
	if p.pos < len(p.data) && p.data[p.pos] == ']' {
		p.pos++
		return out, nil
	}
	for {
		p.skipSpace()
		v, err := p.value()
		if err != nil {
			return nil, err
		}
		out = append(out, v)
		p.skipSpace()
		if p.pos >= len(p.data) {
			return nil, fmt.Errorf("unexpected end of array")
		}
		if p.data[p.pos] == ',' {
			p.pos++
			continue
		}
		if p.data[p.pos] == ']' {
			p.pos++
			return out, nil
		}
		return nil, fmt.Errorf("expected ',' or ']' at %d", p.pos)
	}
}

func (p *parser) str() (string, error) {
	p.pos++ // opening quote
	var b bytes.Buffer
	for {
		if p.pos >= len(p.data) {
			return "", fmt.Errorf("unterminated string")
		}
		c := p.data[p.pos]
		switch {
		case c == '"':
			p.pos++
			return b.String(), nil
		case c == '\\':
			p.pos++
			if p.pos >= len(p.data) {
				return "", fmt.Errorf("unterminated escape")
			}
			e := p.data[p.pos]
			p.pos++
			switch e {
			case '"', '\\', '/':
				b.WriteByte(e)
			case 'b':
				b.WriteByte('\b')
			case 'f':
				b.WriteByte('\f')
			case 'n':
				b.WriteByte('\n')
			case 'r':
				b.WriteByte('\r')
			case 't':
				b.WriteByte('\t')
			case 'u':
				r, err := p.hex4()
				if err != nil {
					return "", err
				}
				if utf16.IsSurrogate(r) && p.pos+1 < len(p.data) && p.data[p.pos] == '\\' && p.data[p.pos+1] == 'u' {
					save := p.pos
					p.pos += 2
					r2, err := p.hex4()
					if err != nil {
						return "", err
					}
					if dec := utf16.DecodeRune(r, r2); dec != utf8.RuneError {
						r = dec
					} else {
						p.pos = save
					}
				}
				var buf [4]byte
				n := utf8.EncodeRune(buf[:], r)
				b.Write(buf[:n])
			default:
				return "", fmt.Errorf("invalid escape \\%c", e)
			}
		case c < 0x20:
			return "", fmt.Errorf("control character in string at %d", p.pos)
		default:
			b.WriteByte(c)
			p.pos++
		}
	}
}

func (p *parser) hex4() (rune, error) {
	if p.pos+4 > len(p.data) {
		return 0, fmt.Errorf("short \\u escape")
	}
	v, err := strconv.ParseUint(string(p.data[p.pos:p.pos+4]), 16, 32)
	if err != nil {
		return 0, fmt.Errorf("invalid \\u escape")
	}
	p.pos += 4
	return rune(v), nil
}

func (p *parser) number() (any, error) {
	start := p.pos
	if p.data[p.pos] == '-' {
		p.pos++
	}
	isFloat := false
	for p.pos < len(p.data) {
		c := p.data[p.pos]
		if c >= '0' && c <= '9' {
			p.pos++
			continue
		}
		if c == '.' || c == 'e' || c == 'E' || c == '+' || c == '-' {
			isFloat = true
			p.pos++
			continue
		}
		break
	}
	text := string(p.data[start:p.pos])
	if isFloat {
		f, err := strconv.ParseFloat(text, 64)
		if err != nil {
			return nil, fmt.Errorf("invalid number %q", text)
		}
		return Flt(f), nil
	}
	if i, err := strconv.ParseInt(text, 10, 64); err == nil {
		return Int(i), nil
	}
	if _, ok := new(big.Int).SetString(text, 10); !ok {
		return nil, fmt.Errorf("invalid number %q", text)
	}
	return Number{Big: text}, nil
}

// deepEqual compares two parsed JSON values the way Ruby `==` compares the
// corresponding Hash/Array/String/Numeric/nil/boolean values. Hash order is
// irrelevant to Ruby Hash equality and is irrelevant here.
func deepEqual(a, b any) bool {
	switch x := a.(type) {
	case nil:
		return b == nil
	case bool:
		y, ok := b.(bool)
		return ok && x == y
	case string:
		y, ok := b.(string)
		return ok && x == y
	case Number:
		return numEqual(a, b)
	case []string:
		return deepEqual(toAnySlice(x), b)
	case []any:
		var y []any
		switch yy := b.(type) {
		case []any:
			y = yy
		case []string:
			y = toAnySlice(yy)
		default:
			return false
		}
		if len(x) != len(y) {
			return false
		}
		for i := range x {
			if !deepEqual(x[i], y[i]) {
				return false
			}
		}
		return true
	case *Object:
		y, ok := b.(*Object)
		if !ok || x.Len() != y.Len() {
			return false
		}
		for _, k := range x.keys {
			if !y.Has(k) || !deepEqual(x.values[k], y.values[k]) {
				return false
			}
		}
		return true
	}
	return false
}

func toAnySlice(s []string) []any {
	out := make([]any, len(s))
	for i, v := range s {
		out[i] = v
	}
	return out
}

// deepCopy clones a parsed JSON tree (Marshal.load(Marshal.dump(x))).
func deepCopy(v any) any {
	switch x := v.(type) {
	case *Object:
		out := NewObject()
		for _, k := range x.keys {
			out.Set(k, deepCopy(x.values[k]))
		}
		return out
	case []any:
		out := make([]any, len(x))
		for i, e := range x {
			out[i] = deepCopy(e)
		}
		return out
	default:
		return v
	}
}

// strSlice converts a JSON array of strings to []string (non-strings become "").
func strSlice(v any) []string {
	switch x := v.(type) {
	case []string:
		return x
	case []any:
		out := make([]string, len(x))
		for i, e := range x {
			s, _ := e.(string)
			out[i] = s
		}
		return out
	}
	return nil
}
