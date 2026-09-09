// Sprint: #118; Story-ID: 3abd77da923c
// Imports-only parsing of immutable upstream inputs; no tested code executes.
package main

import (
	"crypto/sha256"
	"encoding/json"
	"fmt"
	"go/parser"
	"go/token"
	"os"
	"strconv"
)

type input struct {
	Path     string `json:"path"`
	Relative string `json:"relative"`
	SHA256   string `json:"sha256"`
}
type output struct {
	Path       string   `json:"path"`
	SHA256     string   `json:"sha256"`
	Package    string   `json:"package"`
	Imports    []string `json:"imports"`
	ParseError string   `json:"parse_error,omitempty"`
}

func main() {
	var inputs []input
	if err := json.NewDecoder(os.Stdin).Decode(&inputs); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(2)
	}
	var result []output
	for _, in := range inputs {
		stat, err := os.Lstat(in.Path)
		if err != nil || !stat.Mode().IsRegular() {
			fmt.Fprintln(os.Stderr, "invalid source", in.Path)
			os.Exit(2)
		}
		data, err := os.ReadFile(in.Path)
		if err != nil || fmt.Sprintf("%x", sha256.Sum256(data)) != in.SHA256 {
			fmt.Fprintln(os.Stderr, "source digest mismatch", in.Path)
			os.Exit(2)
		}
		item := output{Path: in.Relative, SHA256: in.SHA256, Imports: []string{}}
		parsed, err := parser.ParseFile(token.NewFileSet(), in.Relative, data, parser.ImportsOnly|parser.AllErrors)
		if err != nil {
			item.ParseError = err.Error()
		}
		if parsed != nil {
			if parsed.Name != nil {
				item.Package = parsed.Name.Name
			}
			for _, node := range parsed.Imports {
				value, err := strconv.Unquote(node.Path.Value)
				if err != nil {
					item.ParseError = err.Error()
				} else {
					item.Imports = append(item.Imports, value)
				}
			}
		}
		result = append(result, item)
	}
	if err := json.NewEncoder(os.Stdout).Encode(result); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(2)
	}
}
