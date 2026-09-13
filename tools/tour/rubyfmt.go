// Sprint 155 / Story S155.9 / Story-ID 43af37063b09.
//
// Renderings that the retired Ruby comparators embedded in their finding
// strings (`#{value.inspect}`). The findings are part of the sealed ledger, so
// they are reproduced byte for byte here.
package main

import (
	"fmt"
	"strconv"
	"strings"
	"unicode"
	"unicode/utf8"
)

// inspect mirrors Ruby's #inspect for strings, integers, floats, nil, and
// arrays of those.
func inspect(v any) string {
	switch x := v.(type) {
	case nil:
		return "nil"
	case string:
		return inspectString(x)
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
	case []string:
		parts := make([]string, len(x))
		for i, s := range x {
			parts[i] = inspectString(s)
		}
		return "[" + strings.Join(parts, ", ") + "]"
	case []int:
		parts := make([]string, len(x))
		for i, n := range x {
			parts[i] = strconv.Itoa(n)
		}
		return "[" + strings.Join(parts, ", ") + "]"
	case []any:
		parts := make([]string, len(x))
		for i, item := range x {
			parts[i] = inspect(item)
		}
		return "[" + strings.Join(parts, ", ") + "]"
	case [][]string:
		parts := make([]string, len(x))
		for i, item := range x {
			parts[i] = inspect(item)
		}
		return "[" + strings.Join(parts, ", ") + "]"
	}
	return fmt.Sprintf("%v", v)
}

// inspectString mirrors String#inspect for a UTF-8 string.
func inspectString(s string) string {
	var b strings.Builder
	b.WriteByte('"')
	for i := 0; i < len(s); {
		r, size := utf8.DecodeRuneInString(s[i:])
		if r == utf8.RuneError && size == 1 {
			fmt.Fprintf(&b, `\x%02X`, s[i])
			i++
			continue
		}
		switch r {
		case '"':
			b.WriteString(`\"`)
		case '\\':
			b.WriteString(`\\`)
		case '\n':
			b.WriteString(`\n`)
		case '\r':
			b.WriteString(`\r`)
		case '\t':
			b.WriteString(`\t`)
		case '\f':
			b.WriteString(`\f`)
		case '\v':
			b.WriteString(`\v`)
		case '\b':
			b.WriteString(`\b`)
		case '\a':
			b.WriteString(`\a`)
		case 0x1b:
			b.WriteString(`\e`)
		case '#':
			// Ruby escapes an interpolation-looking `#` so the result re-parses.
			if i+1 < len(s) && (s[i+1] == '{' || s[i+1] == '$' || s[i+1] == '@') {
				b.WriteString(`\#`)
			} else {
				b.WriteByte('#')
			}
		default:
			if r < 0x20 || r == 0x7f {
				fmt.Fprintf(&b, `\u%04X`, r)
			} else if r > 0x7f && !unicode.IsPrint(r) {
				fmt.Fprintf(&b, `\u%04X`, r)
			} else {
				b.WriteRune(r)
			}
		}
		i += size
	}
	b.WriteByte('"')
	return b.String()
}
