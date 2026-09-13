#!/usr/bin/env bash
# Sprint: #118; Story: #3; Story-ID: fa07603b71dc
# Sprint: #155; Story: S155.10; Story-ID: 67bdd9fae2b3
#
# Genuine fail-closed mutations. Each case changes a real checked-in input, the
# real gate source, a real candidate manifest, or a real evidence document, and
# then enters the normal production path; there are no diagnosis hooks and
# nothing asserts an outcome into existence.
#
# Phase A mutates provisioning, the candidate binding and the gate itself
# (each source mutation is applied to a private copy of the repository, which
# rebuilds its own gate binary through the same build.sh as production).
# Phase B mutates a complete evidence document.
#
# Inputs, as before: GBE_CANDIDATE (the authenticated candidate manifest) and
# BASHY_BIN (its launcher). GBE_EVIDENCE may name the authenticated evidence
# chain Phase B mutates; the default is the historical committed location,
# tests/go-by-example/sprint118-story3-candidate001.jsonl.fail.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
: "${GBE_CANDIDATE:?set GBE_CANDIDATE to the authenticated candidate manifest}"
: "${BASHY_BIN:?set BASHY_BIN to the authenticated candidate launcher}"
exec "${ROOT}/tools/go-by-example/gbe.sh" tamper-tests "$@"
