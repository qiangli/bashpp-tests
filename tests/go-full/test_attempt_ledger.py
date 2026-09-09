#!/usr/bin/env python3
# Sprint: #118; Story: #17; Story-ID: b5d3bd1bd24c
"""Check that a wall-clock-capped attempt is accounted for without completion claims."""
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

REPO = Path(__file__).resolve().parents[2]
TOOL = REPO / 'tools/go-full/attempt_ledger.py'

CATALOG = [
    {'action': 'compile', 'phase_contract': ['compile-original-program']},
    {'action': 'errorcheck', 'phase_contract': ['compile-original-program', 'match-expected-diagnostics']},
]
INVENTORY = {
    'testdir-roots.jsonl': [
        {'id': 'testdir:a', 'recipe': {'action': 'compile'}},
        {'id': 'testdir:b', 'recipe': {'action': 'errorcheck'}},
        {'id': 'testdir:c', 'recipe': {'action': 'unknown-action'}},
    ],
    'typechecker-roots.jsonl': [{'id': 'types:x'}],
    'package-roots.jsonl': [{'id': 'pkg:y', 'package': 'p'}],
}


def row(rid, verdict, **extra):
    record = {'id': rid, 'product_verdict': verdict, 'modes': {}, 'unfinished_phases': [],
              'native_observation': {'status': 'pass'}}
    record.update(extra)
    return record


class AttemptLedgerTests(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        self.inventory = self.tmp / 'inventory'
        self.inventory.mkdir()
        (self.inventory / 'action-catalog.json').write_text(json.dumps(CATALOG))
        for name, rows in INVENTORY.items():
            (self.inventory / name).write_text(''.join(json.dumps(r) + '\n' for r in rows))
        self.evidence = self.tmp / 'evidence'
        self.evidence.mkdir()

    def retain(self, rows):
        (self.evidence / 'roots.jsonl').write_text(''.join(json.dumps(r) + '\n' for r in rows))

    def run_tool(self, label='attempt', elapsed=1800.0, cap=1800.0, code=143):
        out = self.tmp / ('out-' + label)
        result = subprocess.run(
            [sys.executable, str(TOOL), '--inventory', str(self.inventory), '--evidence', str(self.evidence),
             '--output', str(out), '--label', label, '--elapsed-seconds', str(elapsed),
             '--cap-seconds', str(cap), '--exit-code', str(code)],
            capture_output=True, text=True)
        return result, out

    def test_capped_attempt_accounts_for_every_root_without_claiming_completion(self):
        self.retain([row('testdir:a', 'PASS', execution={'verdict': 'PASS'}),
                     row('testdir:b', 'FAIL', unfinished_phases=['match-expected-diagnostics'])])
        result, out = self.run_tool()
        self.assertEqual(result.returncode, 0, result.stderr)
        report = json.loads((out / 'attempt-attempt.json').read_text())
        self.assertFalse(report['completion_claimed'])
        self.assertFalse(report['attempt_complete'])
        self.assertEqual(report['inventory_roots'], 5)
        self.assertEqual(report['attempted_roots'], 2)
        self.assertEqual(report['not_attempted_roots'], 3)
        self.assertEqual(report['not_attempted_by_axis'], {'package': 1, 'testdir': 1, 'typechecker': 1})
        # Unreached roots are charged their exact phase obligations, never a verdict.
        self.assertEqual(report['not_attempted_phases'], {
            'build-test-harness': 1, 'check-original-fixture': 1, 'enumerate-runtime-tests': 1,
            'execute-product-test-bodies': 1, 'join-all-runtime-results': 1,
            'match-source-positioned-diagnostics': 1, 'resolve-build-ignore-before-action': 1})
        self.assertEqual(report['attempted_unfinished_phases'], {'match-expected-diagnostics': 1})
        self.assertEqual(report['total_missing_phase_references'], 8)
        # Only attempted roots carry verdicts.
        self.assertEqual(report['verdicts_by_axis'], {'testdir': {'FAIL': 1, 'PASS': 1}})

    def test_ledger_marks_unreached_roots_and_keeps_full_denominator(self):
        self.retain([row('testdir:a', 'PASS', execution={'verdict': 'PASS'})])
        _result, out = self.run_tool()
        lines = (out / 'attempt-ledger.tsv').read_text().splitlines()
        self.assertEqual(len(lines), 6)
        states = {line.split('\t')[0]: line.split('\t')[2:4] for line in lines[1:]}
        self.assertEqual(states['testdir:a'], ['ATTEMPTED', 'PASS'])
        for rid in ('testdir:b', 'testdir:c', 'types:x', 'pkg:y'):
            self.assertEqual(states[rid], ['NOT_ATTEMPTED', 'NONE'])

    def test_complete_attempt_is_reported_as_complete(self):
        self.retain([row('testdir:a', 'PASS', execution={'verdict': 'PASS'}),
                     row('testdir:b', 'FAIL'), row('testdir:c', 'FAIL'),
                     row('types:x', 'FAIL'), row('pkg:y', 'UPSTREAM_SKIP')])
        _result, out = self.run_tool()
        report = json.loads((out / 'attempt-attempt.json').read_text())
        self.assertTrue(report['attempt_complete'])
        self.assertEqual(report['not_attempted_roots'], 0)
        self.assertEqual(report['not_attempted_phase_references'], 0)
        self.assertFalse(report['completion_claimed'])

    def test_duplicate_retained_row_rejected(self):
        self.retain([row('testdir:a', 'FAIL'), row('testdir:a', 'PASS', execution={'verdict': 'PASS'})])
        result, _out = self.run_tool()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('duplicate retained row id', result.stderr)

    def test_row_outside_immutable_inventory_rejected(self):
        self.retain([row('testdir:a', 'PASS'), row('testdir:invented', 'PASS')])
        result, _out = self.run_tool()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('outside immutable inventory', result.stderr)


if __name__ == '__main__':
    unittest.main()
