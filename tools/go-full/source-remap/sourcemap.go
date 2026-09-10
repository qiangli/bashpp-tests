// Sprint: #148; Story: #31; Story-ID: 7a1175a64d88
// Validated original-position remapper for bashy-transpile-map-v1 source
// maps. The validation is a Go port of Corpus.valid_source_map? in
// tools/corpus/executor.rb: the map is re-authenticated against the actual
// generated and original bytes, so a caller can never hand this primitive a
// stale or hand-edited map. Every remap is exact: a generated position that
// the map does not record, or that resolves to more than one original
// position, is an error rather than a nearest guess.
package main

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"path"
	"regexp"
	"sort"
	"strings"
)

const (
	mapSchemaVersion = "bashy-transpile-map-v1"
	mapSourceKind    = "go"
	mapFrontEnd      = "gosource-v1"
)

var lowerMarkerRx = regexp.MustCompile(`\A// lower:\d+\z`)

// mapping is one recorded (generated → original) position.
type mapping struct {
	GoLine, GoCol         int
	SourceLine, SourceCol int
	SourceOffset          int
	Node                  string
	SourceFile            string
	SourceFileOffset      int
}

// mappedSource is one original source as the map recorded it.
type mappedSource struct {
	Name   string
	SHA256 string
	Size   int
	Base   int
}

type sourceMap struct {
	Origin   string
	goDigest string
	Mappings []mapping
	Sources  []mappedSource
}

// sourceBytes is an original source as the caller retained it, keyed by the
// name the lowerer used for it.
type sourceBytes struct {
	SHA256 string
	Data   []byte
}

func digest(data []byte) string {
	sum := sha256.Sum256(data)
	return hex.EncodeToString(sum[:])
}

// jsonInt accepts only whole JSON numbers, mirroring Ruby's Integer check.
func jsonInt(v any) (int, bool) {
	n, ok := v.(json.Number)
	if !ok || strings.ContainsAny(n.String(), ".eE") {
		return 0, false
	}
	i, err := n.Int64()
	if err != nil || int64(int(i)) != i {
		return 0, false
	}
	return int(i), true
}

func jsonString(v any) (string, bool) {
	s, ok := v.(string)
	return s, ok
}

func validSourceName(name string) bool {
	if name == "" || strings.Contains(name, "\\") || strings.HasPrefix(name, "/") {
		return false
	}
	for _, r := range name {
		if r < 0x20 || r == 0x7f {
			return false
		}
	}
	clean := path.Clean(name)
	return clean == name && clean != "." && clean != ".." && !strings.HasPrefix(clean, "../")
}

func validShortName(name string) bool {
	return name != "" && !strings.ContainsAny(name, "/\\: \t\r\n")
}

// decodeSourceMap parses the map with strict scalar typing. Unknown keys are
// tolerated exactly as the shared Ruby validator tolerates them.
func decodeSourceMap(data []byte) (*sourceMap, error) {
	dec := json.NewDecoder(strings.NewReader(string(data)))
	dec.UseNumber()
	var raw any
	if err := dec.Decode(&raw); err != nil {
		return nil, fmt.Errorf("source map is not JSON: %v", err)
	}
	var trailing any
	if err := dec.Decode(&trailing); err != io.EOF {
		return nil, errors.New("source map has trailing data")
	}
	obj, ok := raw.(map[string]any)
	if !ok {
		return nil, errors.New("source map is not a JSON object")
	}
	if v, _ := jsonString(obj["schema_version"]); v != mapSchemaVersion {
		return nil, fmt.Errorf("source map schema_version is not %q", mapSchemaVersion)
	}
	m := &sourceMap{}
	if v, ok := jsonString(obj["origin"]); !ok || v == "" {
		return nil, errors.New("source map origin must be a nonempty string")
	} else {
		m.Origin = v
	}
	if v, _ := jsonString(obj["source_kind"]); v != mapSourceKind {
		return nil, fmt.Errorf("source map source_kind is not %q", mapSourceKind)
	}
	if v, _ := jsonString(obj["front_end"]); v != mapFrontEnd {
		return nil, fmt.Errorf("source map front_end is not %q", mapFrontEnd)
	}
	m.goDigest, _ = jsonString(obj["go_digest"])
	rawMappings, ok := obj["mappings"].([]any)
	if !ok {
		return nil, errors.New("source map mappings must be an array")
	}
	rawSources, ok := obj["sources"].([]any)
	if !ok {
		return nil, errors.New("source map sources must be an array")
	}
	for i, rs := range rawSources {
		so, ok := rs.(map[string]any)
		if !ok {
			return nil, fmt.Errorf("source map sources[%d] is not an object", i)
		}
		name, ok := jsonString(so["name"])
		if !ok || !validSourceName(name) {
			return nil, fmt.Errorf("source map sources[%d].name is not a safe relative source name", i)
		}
		sum, _ := jsonString(so["sha256"])
		size, sizeOK := jsonInt(so["size"])
		base, baseOK := jsonInt(so["base"])
		if !sizeOK || !baseOK {
			return nil, fmt.Errorf("source map sources[%d] size/base must be integers", i)
		}
		m.Sources = append(m.Sources, mappedSource{Name: name, SHA256: sum, Size: size, Base: base})
	}
	for i, rm := range rawMappings {
		mo, ok := rm.(map[string]any)
		if !ok {
			return nil, fmt.Errorf("source map mappings[%d] is not an object", i)
		}
		var e mapping
		ints := map[string]*int{"go_line": &e.GoLine, "go_col": &e.GoCol, "source_line": &e.SourceLine, "source_col": &e.SourceCol,
			"source_offset": &e.SourceOffset, "source_file_offset": &e.SourceFileOffset}
		for key, dst := range ints {
			v, ok := jsonInt(mo[key])
			if !ok {
				return nil, fmt.Errorf("source map mappings[%d].%s must be an integer", i, key)
			}
			*dst = v
		}
		for _, key := range []string{"go_line", "go_col", "source_line", "source_col"} {
			if *ints[key] <= 0 {
				return nil, fmt.Errorf("source map mappings[%d].%s must be positive", i, key)
			}
		}
		if e.SourceOffset < 0 {
			return nil, fmt.Errorf("source map mappings[%d].source_offset must not be negative", i)
		}
		if e.Node, ok = jsonString(mo["node"]); !ok || e.Node == "" {
			return nil, fmt.Errorf("source map mappings[%d].node must be a nonempty string", i)
		}
		if e.SourceFile, ok = jsonString(mo["source_file"]); !ok {
			return nil, fmt.Errorf("source map mappings[%d].source_file must be a string", i)
		}
		m.Mappings = append(m.Mappings, e)
	}
	return m, nil
}

// expectedPositions applies the lowerer's next-nonempty-line marker contract
// to the generated bytes: every `// lower:N` marker names the next nonempty
// line, and the map must record exactly those positions, in order.
func expectedPositions(generated []byte) ([][2]int, error) {
	lines := strings.Split(string(generated), "\n")
	var positions [][2]int
	pending := false
	for index, line := range lines {
		stripped := strings.TrimSpace(line)
		if strings.HasPrefix(stripped, "// lower:") {
			if !lowerMarkerRx.MatchString(stripped) {
				return nil, fmt.Errorf("generated line %d has a malformed lower marker", index+1)
			}
			pending = true
		} else if pending && stripped != "" {
			positions = append(positions, [2]int{index + 1, len(line) - len(strings.TrimLeft(line, "\t ")) + 1})
			pending = false
		}
	}
	if pending {
		return nil, errors.New("generated file ends with a dangling lower marker")
	}
	return positions, nil
}

// validateSourceMap re-authenticates the map against the actual generated
// bytes and every retained original. generatedSHA256 is the caller's own
// record of the generated file; sources are keyed by the lowerer's names.
func validateSourceMap(m *sourceMap, generated []byte, generatedSHA256 string, sources map[string]sourceBytes) error {
	if len(sources) == 0 {
		return errors.New("source map validation needs at least one retained original source")
	}
	actual := digest(generated)
	if generatedSHA256 != actual {
		return errors.New("generated file digest disagrees with its record")
	}
	if m.goDigest != "sha256:"+actual {
		return errors.New("source map go_digest disagrees with the generated bytes")
	}
	names := make([]string, 0, len(sources))
	for name := range sources {
		names = append(names, name)
	}
	sort.Strings(names)
	if len(m.Sources) != len(names) {
		return errors.New("source map sources do not name exactly the retained originals")
	}
	for i, src := range m.Sources {
		if src.Name != names[i] {
			return errors.New("source map sources do not name exactly the retained originals")
		}
	}
	if m.Origin != m.Sources[0].Name {
		return errors.New("source map origin is not the first retained original")
	}
	base := 0
	for _, src := range m.Sources {
		rec := sources[src.Name]
		actualSum := digest(rec.Data)
		if rec.SHA256 != actualSum {
			return fmt.Errorf("retained original %s digest disagrees with its record", src.Name)
		}
		if src.SHA256 != actualSum {
			return fmt.Errorf("source map digest for %s disagrees with the original bytes", src.Name)
		}
		if src.Size != len(rec.Data) {
			return fmt.Errorf("source map size for %s disagrees with the original bytes", src.Name)
		}
		if src.Base != base {
			return fmt.Errorf("source map base for %s is not the ordered concatenation offset", src.Name)
		}
		base += src.Size + 1
	}
	positions, err := expectedPositions(generated)
	if err != nil {
		return err
	}
	if len(positions) != len(m.Mappings) {
		return fmt.Errorf("source map records %d positions but the generated markers name %d", len(m.Mappings), len(positions))
	}
	generatedLines := strings.Split(string(generated), "\n")
	for i, e := range m.Mappings {
		if e.GoLine != positions[i][0] || e.GoCol != positions[i][1] {
			return fmt.Errorf("source map mappings[%d] generated position %d:%d is not marker position %d:%d", i, e.GoLine, e.GoCol, positions[i][0], positions[i][1])
		}
		rec, ok := sources[e.SourceFile]
		if !ok {
			return fmt.Errorf("source map mappings[%d] names unknown source %q", i, e.SourceFile)
		}
		var meta *mappedSource
		for j := range m.Sources {
			if m.Sources[j].Name == e.SourceFile {
				meta = &m.Sources[j]
			}
		}
		if e.SourceFileOffset+meta.Base != e.SourceOffset {
			return fmt.Errorf("source map mappings[%d] offsets disagree", i)
		}
		if e.SourceFileOffset < 0 || e.SourceFileOffset > len(rec.Data) {
			return fmt.Errorf("source map mappings[%d] offset is outside %s", i, e.SourceFile)
		}
		prefix := rec.Data[:e.SourceFileOffset]
		line := strings.Count(string(prefix), "\n") + 1
		col := e.SourceFileOffset - (strings.LastIndex(string(prefix), "\n") + 1) + 1
		if e.SourceLine != line || e.SourceCol != col {
			return fmt.Errorf("source map mappings[%d] original position %d:%d is not offset %d (%d:%d)", i, e.SourceLine, e.SourceCol, e.SourceFileOffset, line, col)
		}
		if e.GoLine > len(generatedLines) || e.GoCol > len(generatedLines[e.GoLine-1])+1 {
			return fmt.Errorf("source map mappings[%d] generated position is outside the generated file", i)
		}
	}
	return nil
}

// position is an original-source position produced by the remapper. Col is
// only meaningful when ColumnExact is set: the lowered text differs from the
// original, so a column that is not the recorded node start has no original
// counterpart and is reported line-only. Verified is set when the diagnostic
// already claimed an original position (a //line directive in the lowered
// output) and the map independently records that position.
type position struct {
	File        string `json:"file"`
	Line        int    `json:"line"`
	Col         int    `json:"column,omitempty"`
	ColumnExact bool   `json:"column_exact"`
	Node        string `json:"node"`
	Verified    bool   `json:"verified_claim,omitempty"`
}

func (p position) String() string {
	if p.ColumnExact {
		return fmt.Sprintf("%s:%d:%d", p.File, p.Line, p.Col)
	}
	return fmt.Sprintf("%s:%d", p.File, p.Line)
}

// remapper indexes validated maps by the generated file name as it appears
// in product diagnostics.
type remapper struct {
	units     map[string]map[int]mapping   // generated short → generated line → mapping
	originals map[string]map[int][]mapping // original short → original line → recorded targets
	shorts    map[string]string            // lowerer source name → diagnostic short name
	refRx     *regexp.Regexp
}

func newRemapper() *remapper {
	return &remapper{units: map[string]map[int]mapping{}, originals: map[string]map[int][]mapping{}, shorts: map[string]string{}}
}

// add registers one validated map under the generated file's diagnostic name.
// shorts maps each lowerer source name to the name used in diagnostics and
// ERROR annotations. Ambiguity is rejected at registration: two maps for one
// generated name, or a generated name that is also an original name, would
// make a diagnostic prefix mean two different things.
func (r *remapper) add(generatedShort string, m *sourceMap, shorts map[string]string) error {
	if !validShortName(generatedShort) {
		return errors.New("generated file needs a safe diagnostic name")
	}
	if _, dup := r.units[generatedShort]; dup {
		return fmt.Errorf("ambiguous remap: two maps claim generated file %q", generatedShort)
	}
	for _, short := range r.shorts {
		if short == generatedShort {
			return fmt.Errorf("ambiguous remap: generated file %q is also an original source name", generatedShort)
		}
		if _, generated := r.units[short]; generated {
			return fmt.Errorf("ambiguous remap: original source name %q is also a generated file", short)
		}
	}
	unitShorts := map[string]string{}
	for _, src := range m.Sources {
		short, ok := shorts[src.Name]
		if !ok || !validShortName(short) {
			return fmt.Errorf("source %q has no diagnostic short name", src.Name)
		}
		if short == generatedShort {
			return fmt.Errorf("ambiguous remap: generated file %q is also an original source name", generatedShort)
		}
		if other, dup := unitShorts[short]; dup && other != src.Name {
			return fmt.Errorf("ambiguous remap: diagnostic name %q names two sources", short)
		}
		unitShorts[short] = src.Name
		if existing, seen := r.shorts[src.Name]; seen && existing != short {
			return fmt.Errorf("ambiguous remap: source %q has two diagnostic names", src.Name)
		}
		for name, existing := range r.shorts {
			if existing == short && name != src.Name {
				return fmt.Errorf("ambiguous remap: diagnostic name %q names two sources", short)
			}
		}
	}
	index := map[int]mapping{}
	for _, e := range m.Mappings {
		if prior, dup := index[e.GoLine]; dup && (prior.SourceFile != e.SourceFile || prior.SourceLine != e.SourceLine) {
			return fmt.Errorf("ambiguous remap: generated line %d of %q has two original positions", e.GoLine, generatedShort)
		}
		index[e.GoLine] = e
	}
	for _, src := range m.Sources {
		r.shorts[src.Name] = shorts[src.Name]
		if r.originals[shorts[src.Name]] == nil {
			r.originals[shorts[src.Name]] = map[int][]mapping{}
		}
	}
	for _, e := range m.Mappings {
		lines := r.originals[shorts[e.SourceFile]]
		lines[e.SourceLine] = append(lines[e.SourceLine], e)
	}
	r.units[generatedShort] = index
	r.refRx = nil
	return nil
}

// remap resolves one diagnostic position. col 0 means the diagnostic carried
// no column. A position on a generated file is looked up directly. A position
// that already names an original file is a claim made by a //line directive
// in the lowered output; it is accepted only when the map independently
// records that original line as a lowered node start, so the claim is
// verified rather than trusted.
func (r *remapper) remap(file string, line, col int) (position, error) {
	if index, ok := r.units[file]; ok {
		e, ok := index[line]
		if !ok {
			return position{}, fmt.Errorf("unmapped generated position %s:%d", file, line)
		}
		p := position{File: r.shorts[e.SourceFile], Line: e.SourceLine, Node: e.Node}
		if col == e.GoCol {
			p.Col, p.ColumnExact = e.SourceCol, true
		}
		return p, nil
	}
	if lines, ok := r.originals[file]; ok {
		targets := lines[line]
		if len(targets) == 0 {
			return position{}, fmt.Errorf("unverified original position %s:%d is not a recorded lowering target", file, line)
		}
		p := position{File: file, Line: line, Verified: true}
		var exact []mapping
		for _, e := range targets {
			if col == e.SourceCol {
				exact = append(exact, e)
			}
		}
		if len(exact) == 1 {
			p.Col, p.ColumnExact, p.Node = exact[0].SourceCol, true, exact[0].Node
			return p, nil
		}
		if len(exact) > 1 || len(targets) > 1 {
			return position{}, fmt.Errorf("ambiguous original position %s:%d has %d lowering targets", file, line, len(targets))
		}
		p.Node = targets[0].Node
		return p, nil
	}
	return position{}, fmt.Errorf("unmapped file %q", file)
}

// referenceRx matches every generated-file or claimed-original position
// reference embedded in a message body, e.g. "previous declaration at
// gen.go:9:2". Each is remapped or verified exactly like a prefix position.
func (r *remapper) referenceRx() *regexp.Regexp {
	if r.refRx == nil {
		names := make([]string, 0, len(r.units)+len(r.originals))
		for name := range r.units {
			names = append(names, regexp.QuoteMeta(name))
		}
		for name := range r.originals {
			names = append(names, regexp.QuoteMeta(name))
		}
		sort.Strings(names)
		r.refRx = regexp.MustCompile(`(?:^|[^\w./-])(` + strings.Join(names, "|") + `):(\d+)(?::(\d+))?`)
	}
	return r.refRx
}
