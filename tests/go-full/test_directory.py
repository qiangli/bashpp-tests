#!/usr/bin/env python3
"""Check that real pinned directory package/phase boundaries stay explicit."""
import json
from pathlib import Path
import unittest

REPO = Path(__file__).resolve().parents[2]

class DirectoryLedgerTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.rows = [json.loads(line) for line in (REPO / 'docs/go-full/directory-phases.jsonl').read_text().splitlines()]

    def test_complete_directory_denominator_and_no_execution_credit(self):
        self.assertEqual(len(self.rows), 290)
        self.assertEqual(sum(len(row['tested_packages']) for row in self.rows), 635)
        self.assertTrue(all(row['execution_claim'] is False for row in self.rows))
        self.assertEqual({phase['status'] for row in self.rows for phase in row['phases']}, {'not-executed'})

    def test_tested_imports_never_native_forward(self):
        edges = [edge for row in self.rows for edge in row['import_edges'] if edge['kind'] == 'tested-source-package']
        self.assertEqual(len(edges), 362)
        self.assertTrue(all(edge['native_forwarding_permitted'] is False for edge in edges))
        for row in self.rows:
            ids = {node['id'] for node in row['tested_packages']}
            for edge in row['import_edges']:
                self.assertIn(edge['from'], ids)
                if edge['kind'] == 'tested-source-package':
                    self.assertIn(edge['to'], ids)

    def test_directory_errorcheck_then_run_recompiles_and_links_last(self):
        rows = [row for row in self.rows if row['action'] == 'errorcheckandrundir']
        self.assertEqual(len(rows), 5)
        for row in rows:
            nodes = row['tested_packages']
            kinds = [phase['kind'] for phase in row['phases']]
            self.assertEqual(kinds.count('compile-package'), len(nodes))
            self.assertEqual(kinds.count('recompile-package'), len(nodes))
            self.assertEqual(kinds[-3:], ['link-final-package', 'execute-final-package', 'match-expected-output'])
            self.assertEqual(row['phases'][-2]['package'], nodes[-1]['id'])
            self.assertTrue(row['phases'][-2]['tested_dependencies_must_use_same_product_mode'])

    def test_explicit_file_groups_do_not_apply_directory_build_filtering(self):
        for row in self.rows:
            if row['action'] not in ('compiledir', 'rundir', 'errorcheckdir', 'errorcheckandrundir'):
                continue
            for node in row['tested_packages']:
                self.assertIn('file build constraints do not filter', node['file_selection'])

    def test_cgo_is_an_explicit_bridge_requirement(self):
        rows = [row for row in self.rows if row['id'] == 'testdir:fixedbugs/issue47185.go']
        edges = [edge for edge in rows[0]['import_edges'] if edge['source_import'] == 'C']
        self.assertEqual(len(edges), 1)
        self.assertEqual(edges[0]['kind'], 'cgo-boundary')
        self.assertFalse(edges[0]['native_tested_go_forwarding_permitted'])

if __name__ == '__main__':
    unittest.main()
