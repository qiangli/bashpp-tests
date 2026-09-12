// Sprint 155 / Story S155.9 / Story-ID 43af37063b09.
//
// Canonical JSON, byte-compatible with the retired Ruby harness's
// `JSON.generate(deep_sort(record))`: object keys sorted bytewise, no
// whitespace, integers and floats kept distinct (a Ruby Float renders as
// `510.0`, never `510`), strings escaped exactly the way Ruby's generator
// escapes them. Every ledger root digest is a SHA-256 over these bytes, so
// this layer is what makes a Go-produced ledger byte-equivalent to the
// retained Ruby-produced ones.
//
// The in-memory model is the generic one the Ruby code used: map[string]any,
// []any, string, bool, nil, int64 (integer literal) and float64 (float
// literal). Decoding preserves the literal class; encoding renders it back.
package main

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"math"
	"sort"
	"strconv"
	"strings"
	"unicode/utf8"
)

// canonical renders a value as canonical JSON (deep-sorted keys).
func canonical(value any) string {
	var buf bytes.Buffer
	if err := writeJSON(&buf, value); err != nil {
		panic(err)
	}
	return buf.String()
}

func writeJSON(buf *bytes.Buffer, value any) error {
	switch v := value.(type) {
	case nil:
		buf.WriteString("null")
	case bool:
		if v {
			buf.WriteString("true")
		} else {
			buf.WriteString("false")
		}
	case string:
		writeJSONString(buf, v)
	case int:
		buf.WriteString(strconv.FormatInt(int64(v), 10))
	case int64:
		buf.WriteString(strconv.FormatInt(v, 10))
	case float64:
		if math.IsNaN(v) || math.IsInf(v, 0) {
			return fmt.Errorf("json: non-finite float %v", v)
		}
		buf.WriteString(rubyFloat(v))
	case []string:
		buf.WriteByte('[')
		for i, item := range v {
			if i > 0 {
				buf.WriteByte(',')
			}
			writeJSONString(buf, item)
		}
		buf.WriteByte(']')
	case []any:
		buf.WriteByte('[')
		for i, item := range v {
			if i > 0 {
				buf.WriteByte(',')
			}
			if err := writeJSON(buf, item); err != nil {
				return err
			}
		}
		buf.WriteByte(']')
	case map[string]any:
		keys := make([]string, 0, len(v))
		for key := range v {
			keys = append(keys, key)
		}
		sort.Strings(keys)
		buf.WriteByte('{')
		for i, key := range keys {
			if i > 0 {
				buf.WriteByte(',')
			}
			writeJSONString(buf, key)
			buf.WriteByte(':')
			if err := writeJSON(buf, v[key]); err != nil {
				return err
			}
		}
		buf.WriteByte('}')
	default:
		return fmt.Errorf("json: unsupported value %T", value)
	}
	return nil
}

// Ruby's generator escapes `"`, `\` and the C0 controls (\b \f \n \r \t by
// name, the rest as \u00XX). Everything else, including `/`, DEL and every
// non-ASCII code point, is emitted raw.
func writeJSONString(buf *bytes.Buffer, s string) {
	buf.WriteByte('"')
	for i := 0; i < len(s); i++ {
		c := s[i]
		switch c {
		case '"':
			buf.WriteString(`\"`)
		case '\\':
			buf.WriteString(`\\`)
		case '\b':
			buf.WriteString(`\b`)
		case '\f':
			buf.WriteString(`\f`)
		case '\n':
			buf.WriteString(`\n`)
		case '\r':
			buf.WriteString(`\r`)
		case '\t':
			buf.WriteString(`\t`)
		default:
			if c < 0x20 {
				fmt.Fprintf(buf, `\u%04x`, c)
			} else {
				buf.WriteByte(c)
			}
		}
	}
	buf.WriteByte('"')
}

// rubyFloat renders a float64 exactly as Ruby's Float#to_s does: the shortest
// round-trip digits, decimal notation while the decimal exponent lies in
// -4 < e <= 16, otherwise `d.ddde[+-]XX`, and always at least one digit after
// the point.
func rubyFloat(f float64) string {
	if f == 0 {
		if math.Signbit(f) {
			return "-0.0"
		}
		return "0.0"
	}
	sign := ""
	if f < 0 {
		sign = "-"
		f = -f
	}
	// Shortest digits that round-trip, as a digit string and a decimal exponent
	// such that value = 0.d1d2... * 10^decpt.
	e := strconv.FormatFloat(f, 'e', -1, 64) // d.ddddde±XX
	mant, expPart, _ := strings.Cut(e, "e")
	exp, _ := strconv.Atoi(expPart)
	digits := strings.Replace(mant, ".", "", 1)
	decpt := exp + 1
	if decpt > 0 && decpt <= 16 {
		if len(digits) <= decpt {
			return sign + digits + strings.Repeat("0", decpt-len(digits)) + ".0"
		}
		return sign + digits[:decpt] + "." + digits[decpt:]
	}
	if decpt <= 0 && decpt > -4 {
		return sign + "0." + strings.Repeat("0", -decpt) + digits
	}
	frac := digits[1:]
	if frac == "" {
		frac = "0"
	}
	return fmt.Sprintf("%s%s.%se%+03d", sign, digits[:1], frac, decpt-1)
}

// ------------------------------------------------------------------ decoding

type jsonDecoder struct {
	data   []byte
	pos    int
	path   []string
	orders map[string][]string
}

// parseJSON decodes one JSON document into the generic model. Integer literals
// become int64, everything else numeric becomes float64.
func parseJSON(data []byte) (any, error) {
	d := &jsonDecoder{data: data}
	d.skipSpace()
	value, err := d.value()
	if err != nil {
		return nil, err
	}
	d.skipSpace()
	if d.pos != len(d.data) {
		return nil, fmt.Errorf("json: trailing data at offset %d", d.pos)
	}
	return value, nil
}

func (d *jsonDecoder) skipSpace() {
	for d.pos < len(d.data) {
		switch d.data[d.pos] {
		case ' ', '\t', '\n', '\r':
			d.pos++
		default:
			return
		}
	}
}

func (d *jsonDecoder) value() (any, error) {
	if d.pos >= len(d.data) {
		return nil, fmt.Errorf("json: unexpected end of input")
	}
	switch c := d.data[d.pos]; {
	case c == '{':
		return d.object()
	case c == '[':
		return d.array()
	case c == '"':
		return d.str()
	case c == 't':
		return d.literal("true", true)
	case c == 'f':
		return d.literal("false", false)
	case c == 'n':
		return d.literal("null", nil)
	case c == '-' || (c >= '0' && c <= '9'):
		return d.number()
	default:
		return nil, fmt.Errorf("json: unexpected character %q at offset %d", c, d.pos)
	}
}

func (d *jsonDecoder) literal(word string, value any) (any, error) {
	if !bytes.HasPrefix(d.data[d.pos:], []byte(word)) {
		return nil, fmt.Errorf("json: bad literal at offset %d", d.pos)
	}
	d.pos += len(word)
	return value, nil
}

func (d *jsonDecoder) number() (any, error) {
	start := d.pos
	isFloat := false
	if d.data[d.pos] == '-' {
		d.pos++
	}
	for d.pos < len(d.data) {
		c := d.data[d.pos]
		if c >= '0' && c <= '9' {
			d.pos++
			continue
		}
		if c == '.' || c == 'e' || c == 'E' || c == '+' || c == '-' {
			isFloat = true
			d.pos++
			continue
		}
		break
	}
	text := string(d.data[start:d.pos])
	if isFloat {
		f, err := strconv.ParseFloat(text, 64)
		if err != nil {
			return nil, fmt.Errorf("json: bad number %q", text)
		}
		return f, nil
	}
	i, err := strconv.ParseInt(text, 10, 64)
	if err != nil {
		f, ferr := strconv.ParseFloat(text, 64)
		if ferr != nil {
			return nil, fmt.Errorf("json: bad number %q", text)
		}
		return f, nil
	}
	return i, nil
}

func (d *jsonDecoder) str() (any, error) {
	d.pos++ // opening quote
	var out []byte
	for d.pos < len(d.data) {
		c := d.data[d.pos]
		switch {
		case c == '"':
			d.pos++
			return string(out), nil
		case c == '\\':
			d.pos++
			if d.pos >= len(d.data) {
				return nil, fmt.Errorf("json: unterminated escape")
			}
			esc := d.data[d.pos]
			d.pos++
			switch esc {
			case '"', '\\', '/':
				out = append(out, esc)
			case 'b':
				out = append(out, '\b')
			case 'f':
				out = append(out, '\f')
			case 'n':
				out = append(out, '\n')
			case 'r':
				out = append(out, '\r')
			case 't':
				out = append(out, '\t')
			case 'u':
				if d.pos+4 > len(d.data) {
					return nil, fmt.Errorf("json: short \\u escape")
				}
				r, err := strconv.ParseUint(string(d.data[d.pos:d.pos+4]), 16, 32)
				if err != nil {
					return nil, fmt.Errorf("json: bad \\u escape")
				}
				d.pos += 4
				cp := rune(r)
				if cp >= 0xd800 && cp < 0xdc00 && d.pos+6 <= len(d.data) && d.data[d.pos] == '\\' && d.data[d.pos+1] == 'u' {
					lo, err := strconv.ParseUint(string(d.data[d.pos+2:d.pos+6]), 16, 32)
					if err == nil && lo >= 0xdc00 && lo < 0xe000 {
						cp = 0x10000 + (cp-0xd800)<<10 + (rune(lo) - 0xdc00)
						d.pos += 6
					}
				}
				out = utf8.AppendRune(out, cp)
			default:
				return nil, fmt.Errorf("json: bad escape \\%c", esc)
			}
		default:
			out = append(out, c)
			d.pos++
		}
	}
	return nil, fmt.Errorf("json: unterminated string")
}

func (d *jsonDecoder) array() (any, error) {
	d.pos++
	out := []any{}
	d.skipSpace()
	if d.pos < len(d.data) && d.data[d.pos] == ']' {
		d.pos++
		return out, nil
	}
	for {
		d.skipSpace()
		v, err := d.value()
		if err != nil {
			return nil, err
		}
		out = append(out, v)
		d.skipSpace()
		if d.pos >= len(d.data) {
			return nil, fmt.Errorf("json: unterminated array")
		}
		if d.data[d.pos] == ',' {
			d.pos++
			continue
		}
		if d.data[d.pos] == ']' {
			d.pos++
			return out, nil
		}
		return nil, fmt.Errorf("json: bad array at offset %d", d.pos)
	}
}

func (d *jsonDecoder) object() (any, error) {
	d.pos++
	out := map[string]any{}
	d.skipSpace()
	if d.pos < len(d.data) && d.data[d.pos] == '}' {
		d.pos++
		return out, nil
	}
	for {
		d.skipSpace()
		if d.pos >= len(d.data) || d.data[d.pos] != '"' {
			return nil, fmt.Errorf("json: bad object key at offset %d", d.pos)
		}
		key, err := d.str()
		if err != nil {
			return nil, err
		}
		if d.orders != nil {
			p := strings.Join(d.path, ".")
			d.orders[p] = append(d.orders[p], key.(string))
			d.path = append(d.path, key.(string))
		}
		d.skipSpace()
		if d.pos >= len(d.data) || d.data[d.pos] != ':' {
			return nil, fmt.Errorf("json: missing colon at offset %d", d.pos)
		}
		d.pos++
		d.skipSpace()
		v, err := d.value()
		if d.orders != nil {
			d.path = d.path[:len(d.path)-1]
		}
		if err != nil {
			return nil, err
		}
		out[key.(string)] = v
		d.skipSpace()
		if d.pos >= len(d.data) {
			return nil, fmt.Errorf("json: unterminated object")
		}
		if d.data[d.pos] == ',' {
			d.pos++
			continue
		}
		if d.data[d.pos] == '}' {
			d.pos++
			return out, nil
		}
		return nil, fmt.Errorf("json: bad object at offset %d", d.pos)
	}
}

// ---------------------------------------------------------------- helpers

func sha256hex(data []byte) string {
	sum := sha256.Sum256(data)
	return hex.EncodeToString(sum[:])
}

// jsonEqual compares two generic values by their canonical rendering, so an
// int decoded as int64 equals the int the harness computed.
func jsonEqual(a, b any) bool {
	return canonical(a) == canonical(b)
}

// deepCopy round-trips through canonical JSON.
func deepCopy(value any) any {
	out, err := parseJSON([]byte(canonical(value)))
	if err != nil {
		panic(err)
	}
	return out
}

// Generic accessors. They mirror the loose Ruby reads (`x['k']`, `.dig`,
// `.to_s`, `.to_i`) the harness relied on, returning zero values for absent
// or mistyped fields rather than panicking.

func asMap(v any) map[string]any {
	m, _ := v.(map[string]any)
	return m
}

func asList(v any) []any {
	switch l := v.(type) {
	case []any:
		return l
	case []string:
		out := make([]any, len(l))
		for i, s := range l {
			out[i] = s
		}
		return out
	}
	return nil
}

func asString(v any) string {
	s, _ := v.(string)
	return s
}

// toS mirrors Ruby's to_s for the value classes the ledgers carry.
func toS(v any) string {
	switch x := v.(type) {
	case nil:
		return ""
	case string:
		return x
	case int:
		return strconv.Itoa(x)
	case int64:
		return strconv.FormatInt(x, 10)
	case float64:
		return rubyFloat(x)
	case bool:
		if x {
			return "true"
		}
		return "false"
	default:
		return canonical(v)
	}
}

func asBool(v any) bool {
	b, _ := v.(bool)
	return b
}

// truthy mirrors Ruby truthiness: only nil and false are false.
func truthy(v any) bool {
	if v == nil {
		return false
	}
	if b, ok := v.(bool); ok {
		return b
	}
	return true
}

// asInt returns the integer value of an int/int64/integral float64, with ok=false otherwise.
func asInt(v any) (int64, bool) {
	switch x := v.(type) {
	case int:
		return int64(x), true
	case int64:
		return x, true
	case float64:
		if x == math.Trunc(x) {
			return int64(x), true
		}
	}
	return 0, false
}

// toI mirrors Ruby's `.to_i` on nil/Integer (nil -> 0).
func toI(v any) int64 {
	i, _ := asInt(v)
	return i
}

func asFloat(v any) float64 {
	switch x := v.(type) {
	case int:
		return float64(x)
	case int64:
		return float64(x)
	case float64:
		return x
	}
	return 0
}

// isInteger reports whether the value is an Integer in the Ruby sense.
func isInteger(v any) bool {
	switch v.(type) {
	case int, int64:
		return true
	}
	return false
}

func dig(v any, keys ...string) any {
	cur := v
	for _, key := range keys {
		m, ok := cur.(map[string]any)
		if !ok {
			return nil
		}
		cur, ok = m[key]
		if !ok {
			return nil
		}
	}
	return cur
}

func strList(v any) []string {
	items := asList(v)
	out := make([]string, 0, len(items))
	for _, item := range items {
		out = append(out, asString(item))
	}
	return out
}

func anyList(items []string) []any {
	out := make([]any, len(items))
	for i, s := range items {
		out[i] = s
	}
	return out
}

func sortedKeys(m map[string]any) []string {
	keys := make([]string, 0, len(m))
	for key := range m {
		keys = append(keys, key)
	}
	sort.Strings(keys)
	return keys
}

// countBy groups records by a string field and returns sorted counts, the
// shape of Ruby's `group_by { ... }.transform_values(&:length).sort.to_h`.
func countBy(records []map[string]any, field string) map[string]any {
	counts := map[string]any{}
	for _, record := range records {
		key := asString(record[field])
		counts[key] = toI(counts[key]) + 1
	}
	return counts
}

func containsString(list []string, s string) bool {
	for _, item := range list {
		if item == s {
			return true
		}
	}
	return false
}

func uniqStrings(list []string) []string {
	seen := map[string]bool{}
	out := []string{}
	for _, item := range list {
		if !seen[item] {
			seen[item] = true
			out = append(out, item)
		}
	}
	return out
}

func sortedCopy(list []string) []string {
	out := append([]string{}, list...)
	sort.Strings(out)
	return out
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

// subtract mirrors Ruby's Array#- (every occurrence of a member of b removed from a).
func subtract(a, b []string) []string {
	out := []string{}
	for _, item := range a {
		if !containsString(b, item) {
			out = append(out, item)
		}
	}
	return out
}

// parseJSONOrdered decodes like parseJSON and additionally records, for every
// object, the order its keys appeared in, keyed by the dotted key path
// ("" for the root, "links" for {"links": {...}}). Ruby hashes preserve
// insertion order and a few comparator renderings depend on it.
func parseJSONOrdered(data []byte) (any, map[string][]string, error) {
	d := &jsonDecoder{data: data, orders: map[string][]string{}}
	d.skipSpace()
	value, err := d.value()
	if err != nil {
		return nil, nil, err
	}
	return value, d.orders, nil
}
