#!/usr/bin/env python3
# Sprint: #118; Story: #17; Story-ID: b5d3bd1bd24c
"""Build a complete-attempt ledger for a wall-clock-capped official product run.

`product.rb` writes `roots.jsonl` incrementally and only writes `summary.json`
after the last root, so a run stopped by a manager wall-clock cap leaves exact
per-root evidence but no summary. This tool reads the immutable 3,495-root
inventory and the retained rows and accounts for *every* inventory root: each
root is either attempted (with its retained verdict) or explicitly
NOT_ATTEMPTED. A capped attempt is never reported as a completed replay, and an
unattempted root never receives a verdict of any kind.

Missing-phase counts are exact and split by origin:
  * unfinished phases declared by attempted roots (product.rb `unfinished_phases`)
  * phase obligations of roots the cap never reached, derived from the same
    action catalog and axis rules product.rb uses.
"""
import argparse
import collections
import json
import pathlib
import sys

AXES = ('testdir', 'typechecker', 'package')
TYPECHECKER_PHASES = ['check-original-fixture', 'match-source-positioned-diagnostics']
PACKAGE_PHASES = ['build-test-harness', 'enumerate-runtime-tests',
                  'execute-product-test-bodies', 'join-all-runtime-results']
DEFAULT_TESTDIR_PHASES = ['resolve-build-ignore-before-action']


def read_rows(path):
    with open(path) as stream:
        for line in stream:
            line = line.strip()
            if line:
                yield json.loads(line)


def load_inventory(inventory):
    inventory = pathlib.Path(inventory)
    roots = {}
    for axis, name in (('testdir', 'testdir-roots.jsonl'),
                       ('typechecker', 'typechecker-roots.jsonl'),
                       ('package', 'package-roots.jsonl')):
        for root in read_rows(inventory / name):
            rid = root['id']
            if rid in roots:
                raise SystemExit('duplicate inventory root id: ' + rid)
            root['axis'] = axis
            roots[rid] = root
    return roots


def phase_contract(root, catalog):
    """Phase obligations product.rb would charge to a root it never reached."""
    axis = root['axis']
    if axis == 'typechecker':
        return list(TYPECHECKER_PHASES)
    if axis == 'package':
        return list(PACKAGE_PHASES)
    action = (root.get('recipe') or {}).get('action')
    entry = catalog.get(action)
    return list(entry['phase_contract']) if entry else list(DEFAULT_TESTDIR_PHASES)


def adapter_category(row):
    if 'typechecker_evidence' in row:
        return 'typechecker-adapter'
    if 'execution' in row:
        return 'simple-execution'
    if 'generated_evidence' in row:
        return 'generator-adapter'
    if any('diagnostic_stage' in mode for mode in (row.get('modes') or {}).values()):
        return 'diagnostic-matcher'
    if row.get('product_verdict') == 'UPSTREAM_SKIP':
        return 'native-skip'
    return 'unfinished-recipe-probe'


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--inventory', required=True)
    parser.add_argument('--evidence', required=True)
    parser.add_argument('--output', required=True)
    parser.add_argument('--label', required=True)
    parser.add_argument('--elapsed-seconds', type=float, required=True)
    parser.add_argument('--cap-seconds', type=float, required=True)
    parser.add_argument('--exit-code', type=int, required=True)
    args = parser.parse_args()

    inventory = load_inventory(args.inventory)
    catalog = {entry['action']: entry
               for entry in json.loads((pathlib.Path(args.inventory) / 'action-catalog.json').read_text())}

    evidence = pathlib.Path(args.evidence)
    attempted = {}
    truncated_tail = None
    lines = [line for line in (evidence / 'roots.jsonl').read_text().splitlines() if line.strip()]
    for index, line in enumerate(lines):
        try:
            row = json.loads(line)
        except json.JSONDecodeError:
            # A run stopped mid-write can leave one partial final row. Any
            # earlier bad line is corruption, not a cap, and is fatal.
            if index != len(lines) - 1:
                raise SystemExit('malformed retained row at line %d' % (index + 1))
            truncated_tail = len(line)
            break
        rid = row['id']
        if rid in attempted:
            raise SystemExit('duplicate retained row id: ' + rid)
        if rid not in inventory:
            raise SystemExit('retained row outside immutable inventory: ' + rid)
        attempted[rid] = row

    output = pathlib.Path(args.output)
    output.mkdir(parents=True, exist_ok=True)

    verdicts = collections.defaultdict(collections.Counter)
    categories = collections.defaultdict(collections.Counter)
    attempted_phases = collections.Counter()
    unattempted_phases = collections.Counter()
    attempted_phase_roots = 0
    unattempted_by_axis = collections.Counter()
    attempted_by_axis = collections.Counter()

    ledger = output / (args.label + '-ledger.tsv')
    with ledger.open('w') as stream:
        stream.write('\t'.join(('id', 'axis', 'attempt_state', 'product_verdict',
                                'adapter_category', 'native_status',
                                'unfinished_phase_count', 'unfinished_phases')) + '\n')
        for rid in sorted(inventory):
            root = inventory[rid]
            axis = root['axis']
            row = attempted.get(rid)
            if row is None:
                phases = phase_contract(root, catalog)
                unattempted_phases.update(phases)
                unattempted_by_axis[axis] += 1
                stream.write('\t'.join((rid, axis, 'NOT_ATTEMPTED', 'NONE',
                                        'not-reached-before-wall-clock-cap', 'NONE',
                                        str(len(phases)), ';'.join(phases))) + '\n')
                continue
            phases = row.get('unfinished_phases') or []
            attempted_phases.update(phases)
            attempted_phase_roots += bool(phases)
            attempted_by_axis[axis] += 1
            verdict = row['product_verdict']
            verdicts[axis][verdict] += 1
            category = adapter_category(row)
            categories[category][verdict] += 1
            stream.write('\t'.join((rid, axis, 'ATTEMPTED', verdict, category,
                                    row['native_observation']['status'],
                                    str(len(phases)), ';'.join(phases))) + '\n')

    denominators = collections.Counter(root['axis'] for root in inventory.values())
    complete = len(attempted) == len(inventory)
    report = {
        'schema': 'go-full-capped-attempt-ledger/v1',
        'label': args.label,
        'completion_claimed': False,
        'attempt_complete': complete,
        'wall_clock_cap_seconds': args.cap_seconds,
        'elapsed_seconds': args.elapsed_seconds,
        'driver_exit_code': args.exit_code,
        'inventory_roots': len(inventory),
        'attempted_roots': len(attempted),
        'discarded_truncated_final_row_bytes': truncated_tail,
        'not_attempted_roots': len(inventory) - len(attempted),
        'full_manifest_denominators': dict(sorted(denominators.items())),
        'attempted_by_axis': dict(sorted(attempted_by_axis.items())),
        'not_attempted_by_axis': dict(sorted(unattempted_by_axis.items())),
        'verdicts_by_axis': {axis: dict(sorted(counter.items())) for axis, counter in sorted(verdicts.items())},
        'verdicts_by_adapter': {name: dict(sorted(counter.items())) for name, counter in sorted(categories.items())},
        'attempted_roots_with_unfinished_phases': attempted_phase_roots,
        'attempted_unfinished_phase_references': sum(attempted_phases.values()),
        'attempted_unfinished_phases': dict(sorted(attempted_phases.items())),
        'not_attempted_phase_references': sum(unattempted_phases.values()),
        'not_attempted_phases': dict(sorted(unattempted_phases.items())),
        'total_missing_phase_references': sum(attempted_phases.values()) + sum(unattempted_phases.values()),
        'ledger': str(ledger),
        'claim_scope': ('Wall-clock-capped attempt over the immutable 3,495-root inventory. Every inventory root is '
                        'accounted for as ATTEMPTED with its retained verdict or NOT_ATTEMPTED with its exact unmet '
                        'phase obligations. No completion, no whole-axis PASS and no product credit for native-only '
                        'execution are claimed.'),
    }
    (output / (args.label + '-attempt.json')).write_text(json.dumps(report, indent=2, sort_keys=True) + '\n')
    json.dump({k: v for k, v in report.items()
               if k not in ('attempted_unfinished_phases', 'not_attempted_phases')},
              sys.stdout, indent=2, sort_keys=True)
    print()


if __name__ == '__main__':
    main()
