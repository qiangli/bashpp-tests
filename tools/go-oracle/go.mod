module bashpp-tests/tools/go-oracle

// Pinned to the same release as docs/go-corpus/pin.tsv and docs/go-oracle/pin.tsv.
// The toolchain line is exact rather than a floor, so the driver is never
// silently rebuilt by a different compiler than the one it drives.
go 1.27.0
