// Sprint 155 / Story S155.9 / Story-ID 43af37063b09.
//
// The fail-closed inventory extractor behind tools/tour/refresh.sh — the port
// of the inline Ruby that script carried. It derives tests/tour/inventory.tsv
// from a golang.org/x/website source tree at the pinned commit: every .go
// program under _content/tour (classified by the oracle's own //go:build
// OMIT tags) and every tab-indented inline block inside the .article lessons.
//
// Usage: tour refresh-inventory ROOT VERSION COMMIT GO_MOD_SUM SCHEMA_TSV
package main

import (
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
)

var knownDirectiveRE = regexp.MustCompile(`\A\.(play|image|code|link|video|iframe|caption|background|syntax)\b`)

type inventoryRow []string

func cmdRefreshInventory(args []string) int {
	if len(args) != 5 {
		fmt.Fprintln(os.Stderr, "usage: tour refresh-inventory ROOT VERSION COMMIT GO_MOD_SUM SCHEMA_TSV")
		return 2
	}
	root, version, commit, goModSum, schemaPath := args[0], args[1], args[2], args[3], args[4]
	tour := filepath.Join(root, "_content", "tour")
	fatal := func(format string, a ...any) int {
		fmt.Fprintf(os.Stderr, "FATAL: "+format+"\n", a...)
		return 1
	}

	modLine := ""
	if data, err := os.ReadFile(filepath.Join(root, "go.mod")); err == nil {
		for _, line := range strings.Split(string(data), "\n") {
			if strings.HasPrefix(line, "module ") {
				modLine = line
				break
			}
		}
	}
	if modLine != "module golang.org/x/website" {
		return fatal("go.mod is not module golang.org/x/website: %s", inspectString(modLine))
	}
	if !fileExists(filepath.Join(root, "LICENSE")) {
		return fatal("missing upstream LICENSE in %s", root)
	}
	if !dirExists(tour) {
		return fatal("missing _content/tour in %s", root)
	}

	// Applicability -> differential schema coupling comes from the same table
	// the gate reads: docs/tour/differential-schema.tsv.
	couple := map[string]string{}
	for _, f := range tsvRows(schemaPath) {
		if len(f) != 2 { // Section 1 vocabulary rows have 3 columns
			continue
		}
		couple[f[0]] = f[1]
	}
	if len(couple) == 0 {
		return fatal("differential schema coupling table is empty")
	}

	rows := []inventoryRow{}
	exceptionFor := map[string]string{"applicable_go_program": "none", "build_only_go_program": "none", "excluded_fragment": "fragment"}

	referenced := map[string]int{}
	articles, _ := filepath.Glob(filepath.Join(tour, "*.article"))
	sort.Strings(articles)
	if len(articles) == 0 {
		return fatal("pinned source contains no tour articles")
	}
	for _, art := range articles {
		rel := strings.TrimPrefix(art, tour+"/")
		lines := strings.Split(strings.TrimSuffix(string(readFile(art)), "\n"), "\n")
		block := []string{}
		blockStart := 0
		blockIndex := 0
		flush := func() {
			text := strings.Join(block, "\n") + "\n"
			blockIndex++
			rows = append(rows, inventoryRow{
				fmt.Sprintf("_content/tour/%s#inline-%02d-L%d", rel, blockIndex, blockStart),
				"article_inline_block", fmt.Sprint(blockStart), "excluded_fragment", "exception:fragment",
				couple["excluded_fragment"], fmt.Sprint(len(text)), sha256hex([]byte(text)),
			})
			block = []string{}
		}
		for i, l := range lines {
			if strings.HasPrefix(l, ".") {
				if !knownDirectiveRE.MatchString(l) {
					return fatal("unknown present directive in %s: %s", rel, l)
				}
				fields := strings.Fields(l)
				if fields[0] == ".play" {
					if len(fields) < 2 {
						return fatal(".play without an argument in %s: %s", rel, l)
					}
					arg := fields[1]
					if !strings.HasSuffix(arg, ".go") {
						return fatal(".play argument is not a .go path in %s: %s", rel, arg)
					}
					path := "_content/tour/" + arg
					if !fileExists(filepath.Join(root, path)) {
						return fatal("unresolved .play reference in %s: %s", rel, arg)
					}
					referenced[path]++
				} else if fields[0] == ".image" {
					arg := ""
					if len(fields) > 1 {
						arg = strings.TrimPrefix(fields[1], "/")
					}
					if !fileExists(filepath.Join(root, "_content", arg)) {
						return fatal("unresolved .image asset in %s: %s", rel, arg)
					}
				}
			}
			if strings.HasPrefix(l, "\t") {
				if len(block) == 0 {
					blockStart = i + 1
				}
				block = append(block, l)
			} else if len(block) > 0 {
				flush()
			}
		}
		if len(block) > 0 {
			flush()
		}
	}

	goFiles := []string{}
	filepath.Walk(tour, func(path string, info os.FileInfo, err error) error {
		if err == nil && !info.IsDir() && strings.HasSuffix(path, ".go") {
			goFiles = append(goFiles, path)
		}
		return nil
	})
	sort.Strings(goFiles)
	uiServed := []string{"_content/tour/welcome/sandbox.go"}
	for _, file := range goFiles {
		path := strings.TrimPrefix(file, root+"/")
		text := readFile(file)
		tag, _, _ := strings.Cut(string(text), "\n")
		if !strings.HasPrefix(tag, "//go:build ") {
			return fatal("first line is not a go:build comment: %s", path)
		}
		if !strings.Contains(tag, "OMIT") {
			return fatal(`build comment does not contain "OMIT": %s`, path)
		}
		applicability := "applicable_go_program"
		if strings.Contains(tag, "nobuild") {
			applicability = "excluded_fragment"
		} else if strings.Contains(tag, "norun") {
			applicability = "build_only_go_program"
		}
		var kind string
		switch {
		case referenced[path] > 0:
			kind = "lesson_play_program"
		case strings.HasPrefix(path, "_content/tour/solutions/"):
			kind = "exercise_solution_program"
		case containsString(uiServed, path):
			kind = "ui_sandbox_program"
		default:
			return fatal("inventoried .go file is neither .play-referenced, a solution, nor reviewed UI-served: %s", path)
		}
		schema, ok := couple[applicability]
		if !ok {
			return fatal("no differential schema coupling for %s", applicability)
		}
		rows = append(rows, inventoryRow{path, kind, "n/a", applicability, "exception:" + exceptionFor[applicability],
			schema, fmt.Sprint(len(text)), sha256hex(text)})
	}
	for path := range referenced {
		found := false
		for _, r := range rows {
			if r[0] == path {
				found = true
			}
		}
		if !found {
			return fatal(".play reference never inventoried: %s", path)
		}
	}

	var b strings.Builder
	fmt.Fprintf(&b, "# release\tgolang.org/x/website@%s\n", version)
	fmt.Fprintf(&b, "# commit\t%s\n", commit)
	fmt.Fprintf(&b, "# go_mod_sum\t%s\n", goModSum)
	b.WriteString("# source\thttps://go.googlesource.com/website\n")
	b.WriteString("# license\tBSD-3-Clause\n")
	b.WriteString("# generated_by\ttools/tour/refresh.sh\n")
	b.WriteString("# path\tkind\tstart_line\tapplicability\texception\tdifferential_schema\tbytes\tsha256\n")
	sort.SliceStable(rows, func(i, j int) bool { return rows[i][0] < rows[j][0] })
	for _, r := range rows {
		b.WriteString(strings.Join(r, "\t") + "\n")
	}
	os.Stdout.WriteString(b.String())
	return 0
}
