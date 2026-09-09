#!/usr/bin/env python3
# Sprint: #118; Story: #17; Story-ID: b5d3bd1bd24c
"""Check the reviewed candidate bindings official product validation accepts."""
import hashlib
import json
from pathlib import Path
import re
import unittest

REPO = Path(__file__).resolve().parents[2]
BINDINGS = json.loads((REPO / 'docs/go-full/reviewed-candidates.json').read_text())
SHA256 = re.compile(r'\A[0-9a-f]{64}\Z')


def entry(name):
    return next(c for c in BINDINGS['candidates'] if c['candidate'] == name)


def digest(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


class ReviewedCandidateBindingTests(unittest.TestCase):
    def test_every_binding_names_a_module_context_and_well_formed_digests(self):
        names = [c['candidate'] for c in BINDINGS['candidates']]
        self.assertEqual(len(names), len(set(names)))
        contexts = [c['module_context_sha256'] for c in BINDINGS['candidates']]
        self.assertEqual(len(contexts), len(set(contexts)), 'one module context may not bind two candidates')
        for candidate in BINDINGS['candidates']:
            for key, value in candidate.items():
                if key.endswith('_sha256'):
                    self.assertRegex(value, SHA256, f"{candidate['candidate']}.{key}")
            self.assertIn('module_context_sha256', candidate)
            self.assertIn('candidate_manifest_sha256', candidate)

    def test_tools_default_module_context_is_the_reviewed_candidate006_binding(self):
        source = (REPO / 'tools/go-full/module_context.rb').read_text()
        default = re.search(r"REVIEWED_SHA256 = '([0-9a-f]{64})'", source).group(1)
        self.assertEqual(default, entry('candidate006')['module_context_sha256'])

    def test_candidate018_replaces_published002_and_reuses_the_reviewed_relocated_sdk(self):
        c18 = entry('candidate018')
        self.assertEqual(c18['replaces'], 'published-candidate-002')
        self.assertEqual(entry('published-candidate-002')['status'], 'superseded-by-candidate018')
        self.assertNotEqual(c18['module_context_sha256'], entry('published-candidate-002')['module_context_sha256'])
        self.assertNotEqual(c18['build_cache_root'], '/Users/qiangli/.bashy/sprint118/caches/go-full-published002')
        source = (REPO / 'tools/go-full/authentication.rb').read_text()
        reviewed = re.search(r"REVIEWED_RELOCATION_SHA256 = '([0-9a-f]{64})'", source).group(1)
        self.assertEqual(reviewed, c18['relocation_manifest_sha256'])

    def test_candidate018_build_cache_never_overlaps_a_frozen_input(self):
        c18 = entry('candidate018')
        cache = c18['build_cache_root']
        for protected in (c18['frozen_root'], c18['module_context'], c18['sdk_identity'], c18['candidate_manifest']):
            self.assertFalse(cache == protected or cache.startswith(protected + '/') or protected.startswith(cache + '/'))

    def test_recorded_candidate018_digests_match_host_state_when_present(self):
        c18 = entry('candidate018')
        checked = 0
        for path_key, sha_key in (('candidate_manifest', 'candidate_manifest_sha256'),
                                  ('module_context', 'module_context_sha256'),
                                  ('sdk_identity', 'sdk_identity_sha256'),
                                  ('relocation_manifest', 'relocation_manifest_sha256')):
            path = Path(c18[path_key])
            if not path.is_file():
                continue
            self.assertEqual(digest(path), c18[sha_key], path_key)
            checked += 1
        if not checked:
            self.skipTest('reviewed candidate018 inputs are not present on this host')
        context = Path(c18['module_context'])
        if context.is_file():
            manifest = json.loads(context.read_text())
            # The module context must bind exactly the recorded candidate and frozen sh revision.
            self.assertEqual(manifest['candidate_manifest']['path'], c18['candidate_manifest'])
            self.assertEqual(manifest['candidate_manifest']['sha256'], c18['candidate_manifest_sha256'])
            self.assertEqual(manifest['replacement']['commit'], c18['repositories']['sh'])
            self.assertEqual(manifest['replacement']['path'], c18['frozen_root'] + '/sh')
            self.assertEqual(manifest['cache_root'], c18['build_cache_root'])
            self.assertEqual(len(manifest['modules']), c18['dependency_modules'])
            self.assertEqual(sum(len(m['files']) for m in manifest['modules']), c18['dependency_files'])
            self.assertEqual(manifest['module_files_argument']['sha256'], c18['module_files_argument_sha256'])
            self.assertIs(manifest['original_program_edits'], False)
            self.assertIs(manifest['whole_original_native_delegation'], False)

    def test_frozen_candidate018_tree_is_not_a_binding_output(self):
        c18 = entry('candidate018')
        frozen = c18['frozen_root'] + '/'
        for key in ('module_context', 'build_cache_root', 'module_files_argument_sha256'):
            self.assertFalse(str(c18[key]).startswith(frozen))
        context = Path(c18['module_context'])
        if not context.is_file():
            self.skipTest('module context absent on this host')
        manifest = json.loads(context.read_text())
        # Only read-only references may point into the frozen tree.
        for name, record in manifest['module_files'].items():
            self.assertFalse(record['path'].startswith(frozen), name)
        self.assertFalse(manifest['module_files_argument']['path'].startswith(frozen))
        self.assertFalse(manifest['cache_root'].startswith(frozen))


if __name__ == '__main__':
    unittest.main()
