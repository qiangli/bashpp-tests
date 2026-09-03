# Official Go Corpus Infrastructure

This directory records the first bounded slice of the official Go test corpus
used by the bash++ profile work. It does not claim Bash++ parity and does not
mark unimplemented tests passing.

The reviewed upstream pin is in `pin.tsv`. The machine-readable inventory is
`inventory.tsv`; every listed row is one `go/test/**/*.go` file from the pinned
Go source release, with its action header, byte size, and SHA-256 digest.

Normal gate execution is offline. `tools/go-corpus/validate.sh` reads only the
checked-in pin and inventory unless `GO_CORPUS_ROOT` is set to an already
refreshed local checkout. `tools/go-corpus/refresh.sh` is the explicit networked
step: it downloads the pinned source archive, verifies the archive checksum,
extracts it under `.cache/go-corpus/`, regenerates `inventory.tsv`, and then
runs the same offline validator against the extracted tree.

The upstream Go source release is BSD-3-Clause licensed. This repository stores
only metadata for this slice; the refresh cache contains upstream source and
license files and is intentionally not the conformance result.
