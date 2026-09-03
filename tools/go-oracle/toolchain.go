package main

import (
	"bufio"
	"fmt"
	"os"
	"path/filepath"
	"strings"
)

// TOOLCHAIN IDENTITY.
//
// `go version` is a string a five-line shell script can print, so on its own it
// establishes nothing: the mutation tests in this package prove exactly that by
// sabotaging the toolchain with a stub whose `version` output is perfect. An
// oracle whose only provenance check is forgeable by its own test fixtures is
// not a provenance check.
//
// The gate below is therefore in three layers, and only the first is the
// forgeable one:
//
//  1. `go version` — kept, because a clear release mismatch deserves a clear
//     message, but explicitly NOT trusted.
//  2. GOROOT source identity — the candidate toolchain's own GOROOT must ship
//     the byte-identical upstream sources of the pinned release. Those digests
//     come from the source tarball whose SHA-256 is published on go.dev/dl and
//     verified by tools/go-corpus/refresh.sh, so this layer is anchored in an
//     official checksum rather than in anything the toolchain says about
//     itself. It is platform-independent: the toolchain distribution's src/ is
//     byte-identical to the source release.
//  3. Binary identity — the resolved `go` must be a native executable whose
//     SHA-256 equals the reviewed digest for this GOOS/GOARCH, and that digest
//     is recorded next to the two independent origins it was taken from: the
//     go.dev/dl published archive checksum, and the module-proxy zip hash that
//     sum.golang.org attests for golang.org/toolchain.
//
// A host whose platform has no reviewed row is fatal, not waved through. An
// unreviewed toolchain is exactly the thing this gate exists to refuse.

// toolchainRow is one reviewed (release, goos, goarch) toolchain distribution.
type toolchainRow struct {
	Release       string `json:"release"`
	GOOS          string `json:"goos"`
	GOARCH        string `json:"goarch"`
	GoSHA256      string `json:"go_sha256"`
	DistFilename  string `json:"dist_filename"`
	DistSHA256    string `json:"dist_sha256"`
	Module        string `json:"module"`
	ModuleVersion string `json:"module_version"`
	ModuleZipHash string `json:"module_ziphash"`
}

// gorootProbe is a GOROOT file whose bytes identify the release. Both are taken
// from the officially checksummed source tarball.
type gorootProbe struct {
	Path   string `json:"path"`
	SHA256 string `json:"sha256"`
}

// ToolchainIdentity is the machine-readable record of what was verified. It is
// carried into the run summary so a result file states which toolchain produced
// it and how that was established.
type ToolchainIdentity struct {
	Release       string        `json:"release"`
	GOROOT        string        `json:"goroot"`
	GoBinary      string        `json:"go_binary"`
	GoSHA256      string        `json:"go_sha256"`
	GoBinaryKind  string        `json:"go_binary_kind"`
	ReportedBy    string        `json:"reported_by_go_version"`
	DistFilename  string        `json:"dist_filename"`
	DistSHA256    string        `json:"dist_sha256"`
	Module        string        `json:"module"`
	ModuleVersion string        `json:"module_version"`
	ModuleZipHash string        `json:"module_ziphash"`
	Probes        []gorootProbe `json:"goroot_probes"`
}

// nativeExecutableKind reports the object-file format of data, or "" when the
// bytes are not a native executable at all. A shell script scores "" here, which
// is the whole point: layer 3 must not be satisfiable by a script.
func nativeExecutableKind(data []byte) string {
	switch {
	case len(data) >= 4 && string(data[:4]) == "\x7fELF":
		return "elf"
	case len(data) >= 4 && (string(data[:4]) == "\xcf\xfa\xed\xfe" || string(data[:4]) == "\xce\xfa\xed\xfe" ||
		string(data[:4]) == "\xfe\xed\xfa\xcf" || string(data[:4]) == "\xfe\xed\xfa\xce"):
		return "mach-o"
	case len(data) >= 4 && (string(data[:4]) == "\xca\xfe\xba\xbe" || string(data[:4]) == "\xbe\xba\xfe\xca"):
		return "mach-o-universal"
	case len(data) >= 2 && string(data[:2]) == "MZ":
		return "pe"
	default:
		return ""
	}
}

// loadToolchainPins reads docs/go-oracle/toolchain.tsv.
func loadToolchainPins(pathname string) ([]toolchainRow, []gorootProbe, error) {
	f, err := os.Open(pathname)
	if err != nil {
		return nil, nil, err
	}
	defer f.Close()

	var rows []toolchainRow
	var probes []gorootProbe
	sc := bufio.NewScanner(f)
	for n := 1; sc.Scan(); n++ {
		line := sc.Text()
		if strings.HasPrefix(line, "#") || strings.TrimSpace(line) == "" {
			continue
		}
		fields := strings.Split(line, "\t")
		switch fields[0] {
		case "goroot_probe":
			if len(fields) != 3 {
				return nil, nil, fmt.Errorf("line %d: goroot_probe needs 3 fields, got %d", n, len(fields))
			}
			probes = append(probes, gorootProbe{Path: fields[1], SHA256: fields[2]})
		case "toolchain":
			if len(fields) != 10 {
				return nil, nil, fmt.Errorf("line %d: toolchain needs 10 fields, got %d", n, len(fields))
			}
			rows = append(rows, toolchainRow{
				Release: fields[1], GOOS: fields[2], GOARCH: fields[3], GoSHA256: fields[4],
				DistFilename: fields[5], DistSHA256: fields[6],
				Module: fields[7], ModuleVersion: fields[8], ModuleZipHash: fields[9],
			})
		default:
			return nil, nil, fmt.Errorf("line %d: unknown record kind %q", n, fields[0])
		}
	}
	if err := sc.Err(); err != nil {
		return nil, nil, err
	}
	if len(probes) == 0 {
		return nil, nil, fmt.Errorf("%s records no goroot_probe rows", pathname)
	}
	if len(rows) == 0 {
		return nil, nil, fmt.Errorf("%s records no toolchain rows", pathname)
	}
	return rows, probes, nil
}

// verifyToolchain runs the three layers and returns what it established. Every
// failure is fatal: there is no degraded mode in which the oracle reports
// results from a toolchain it could not identify.
func verifyToolchain(pathname, goTool, release, goroot, goos, goarch, reportedVersion string) *ToolchainIdentity {
	rows, probes, err := loadToolchainPins(pathname)
	if err != nil {
		fatalf("cannot read the toolchain pin %s: %v", pathname, err)
	}

	// Layer 2: GOROOT source identity, anchored in the published source-release
	// checksum rather than in anything the binary reports about itself.
	if goroot == "" {
		fatalf("toolchain %s reports no GOROOT; it cannot be identified", goTool)
	}
	for _, probe := range probes {
		p := filepath.Join(goroot, filepath.FromSlash(probe.Path))
		got, err := fileSHA256(p)
		if err != nil {
			fatalf("toolchain identity: cannot read GOROOT probe %s: %v\n"+
				"  a `go` that answers `version` but has no GOROOT sources is not the pinned toolchain", p, err)
		}
		if got != probe.SHA256 {
			fatalf("toolchain identity: GOROOT probe %s does not match the reviewed %s source release\n"+
				"  expected %s\n  actual   %s", probe.Path, release, probe.SHA256, got)
		}
	}

	// Layer 3: binary identity against the reviewed per-platform digest.
	var row *toolchainRow
	for i := range rows {
		if rows[i].Release == release && rows[i].GOOS == goos && rows[i].GOARCH == goarch {
			row = &rows[i]
			break
		}
	}
	if row == nil {
		fatalf("toolchain identity: no reviewed %s distribution for %s/%s in %s\n"+
			"  This is fatal rather than a skip: an unreviewed toolchain is exactly what\n"+
			"  this gate exists to refuse. Add a reviewed row (see the file's header for\n"+
			"  how each digest is obtained) before running the oracle on this platform.",
			release, goos, goarch, pathname)
	}
	data, err := os.ReadFile(goTool)
	if err != nil {
		fatalf("toolchain identity: cannot read %s: %v", goTool, err)
	}
	kind := nativeExecutableKind(data)
	if kind == "" {
		fatalf("toolchain identity: %s is not a native executable\n"+
			"  `go version` is a string any script can print; the oracle requires the real\n"+
			"  %s/%s distribution binary.", goTool, goos, goarch)
	}
	if got := sha256hex(data); got != row.GoSHA256 {
		fatalf("toolchain identity: %s is not the reviewed %s %s/%s distribution binary\n"+
			"  expected %s\n  actual   %s\n"+
			"  origin of the expected digest: %s (sha256 %s) / %s@%s (%s)",
			goTool, release, goos, goarch, row.GoSHA256, got,
			row.DistFilename, row.DistSHA256, row.Module, row.ModuleVersion, row.ModuleZipHash)
	}

	return &ToolchainIdentity{
		Release: release, GOROOT: goroot, GoBinary: goTool, GoSHA256: row.GoSHA256,
		GoBinaryKind: kind, ReportedBy: reportedVersion,
		DistFilename: row.DistFilename, DistSHA256: row.DistSHA256,
		Module: row.Module, ModuleVersion: row.ModuleVersion, ModuleZipHash: row.ModuleZipHash,
		Probes: probes,
	}
}
