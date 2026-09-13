#!/usr/bin/env bash
# Sprint: #155; Story: S155.10; Story-ID: 67bdd9fae2b3
#
# Offline fail-closed gate for the pinned Go by Example corpus.
#
# The validator itself is the `validate` subcommand of tools/go-by-example/gbe
# (validate.go), a port of the awk/bash checks this file used to carry: the
# exact normalized path SET derived from disk is compared to the inventory SET
# element by element, every copied byte is verified, and counts are only a
# redundant cross-check against the pin. Overridable inputs (GBE_PIN,
# GBE_INVENTORY, GBE_CLASSIFICATION, GBE_SCHEMA, GBE_CORPUS) exist so the tamper
# tests can feed mutated tables without editing the checked-in ones.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
exec "${ROOT}/tools/go-by-example/gbe.sh" validate "$@"
