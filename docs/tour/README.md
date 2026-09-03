# Official Go Tour Inventory

Sprint 98 Story #1 pins the official `golang/tour` source as a bounded
denominator for tour example/page programs. This is provenance and inventory
metadata only; it is not a Bash++ parity claim.

The upstream source is `https://go.googlesource.com/tour` at commit
`11c9ad7eadf5e916a1137ad4dcc113f307f27874`. Upstream files are BSD-3-Clause
licensed; this repository preserves that provenance in `pin.tsv` and does not
vendor the tour source.

Inventory rows live in `inventory.tsv`. They include every `.go` source file in
the pinned tree and every Go-looking page program block in
`tutorial/web-service-gin.md`. Applicability is classified only against the
standing Sprint 98 exception set recorded in `standing-exceptions.tsv`.

Normal gate execution is offline:

```sh
tools/tour/validate.sh
```

To refresh intentionally, clone or update the official source and run:

```sh
tools/tour/refresh.sh
```

No inventory row may be omitted silently. Unsupported rows must cite a standing
exception, and `PLANNED` is not a valid tour inventory state.
