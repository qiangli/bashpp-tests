#!/usr/bin/env python3
"""Bind every observed native skip to raw events and immutable upstream source.

This records applicability evidence without turning a skip into product credit.
"""
import argparse
import collections
import json
from pathlib import Path
import re
import sys
sys.dont_write_bytecode = True
import fixtures


def context(path, line, root):
    lines = path.read_text(errors='strict').splitlines()
    fixtures.require(1 <= line <= len(lines), 'skip callsite outside source: ' + str(path))
    first, last = max(1, line - 12), min(len(lines), line + 8)
    return {'source': fixtures.record(path), 'sdk_relative_path': path.relative_to(root).as_posix(), 'line': line,
            'context_first_line': first, 'context': lines[first - 1:last], 'source_line': lines[line - 1]}


def bind_callsite(package, filename, line, root, by_name):
    direct = root / 'src' / package / filename
    candidates = [direct] if direct.is_file() else by_name.get(filename, [])
    candidates = [p for p in candidates if len(p.read_text().splitlines()) >= line]
    if len(candidates) > 1:
        skip_calls = [p for p in candidates if re.search(r'(Skip|MustHave|SkipFlaky|SkipIf)', p.read_text().splitlines()[line - 1])]
        if skip_calls:
            candidates = skip_calls
    return [context(p, line, root) for p in candidates]


def report(native, identity_path, output):
    fixtures.require(not output.exists(), 'skip review destination already exists')
    identity = fixtures.sdk(identity_path)
    summary = json.loads((native / 'summary.json').read_text())
    fixtures.require(summary['schema'] == 'bridge-native/v1' and summary['product_execution_claim'] is False, 'wrong native evidence schema')
    for key in ('release', 'goos', 'goarch', 'go', 'manifest_sha256', 'source_files', 'merged_files'):
        fixtures.require(summary['sdk'][key] == identity[key], 'skip-review SDK differs from native SDK')
    log = summary['native_stage']['stdout']
    fixtures.require(fixtures.record(log['path']) == log, 'native stdout changed')
    root = Path(identity['root'])
    by_name = collections.defaultdict(list)
    for path in (root / 'src').rglob('*.go'):
        if path.is_file():
            by_name[path.name].append(path)
    outputs = collections.defaultdict(list)
    skips = {}
    for number, raw in enumerate(Path(log['path']).open(), 1):
        event = json.loads(raw)
        key = event['Package'], event.get('Test')
        if event['Action'] == 'output':
            outputs[key].append({'line': number, 'output': event['Output']})
        elif event['Action'] == 'skip':
            fixtures.require(key not in skips, 'duplicate native skip event')
            skips[key] = {'line': number, 'event': event}
    rows = []
    source_pattern = re.compile(r'^\s*([^\s:]+\.go):(\d+):(?:\s|$)(.*)$')
    literal_cache = {}
    binding_cache = {}
    declaration_cache = {}
    bogo_binding = None
    for (package, test), terminal in sorted(skips.items(), key=lambda item: (item[0][0], item[0][1] or '')):
        messages = outputs[(package, test)]
        sites = []
        for item in messages:
            for line in item['output'].splitlines():
                match = source_pattern.match(line)
                if not match:
                    continue
                filename, number, message = match.groups()
                binding_key = (package, Path(filename).name, int(number))
                if binding_key not in binding_cache:
                    binding_cache[binding_key] = bind_callsite(*binding_key, root, by_name)
                bindings = binding_cache[binding_key]
                sites.append({'log_line': item['line'], 'exact_message': message, 'reported_file': filename, 'reported_line': int(number), 'source_bindings': bindings})
        if test is None:
            fixtures.require(any('[no test files]' in m['output'] for m in messages), 'unclassified package skip')
            category = 'native-package-has-no-applicable-test-files'
            reason = '[no test files]'
        elif sites:
            fixtures.require(len(sites[-1]['source_bindings']) == 1, 'skip callsite is ambiguous or unbound: ' + package + ':' + str(test))
            # Last positioned output is retained as the reason candidate, not
            # silently asserted to be a direct Skip call when it is only a log.
            category = 'upstream-positioned-skip'
            reason = sites[-1]['exact_message']
        else:
            category = 'upstream-skip-without-positioned-message'
            reason = None
        declarations = []
        if test:
            name = test.split('/')[0]
            declaration_key = (package, name)
            if declaration_key not in declaration_cache:
                found = []
                for path in sorted((root / 'src' / package).glob('*.go')):
                    if not path.is_file():
                        continue
                    for number, line in enumerate(path.read_text().splitlines(), 1):
                        if re.match(r'func\s+' + re.escape(name) + r'\s*\(', line):
                            found.append(context(path, number, root))
                declaration_cache[declaration_key] = found
            declarations = declaration_cache[declaration_key]
        literal_sites = []
        if test and not sites and not declarations:
            leaf = test.split('/')[-1]
            if leaf not in literal_cache:
                literal_cache[leaf] = []
                # Message-less t.SkipNow calls can live in shared test helpers.
                # Exact subtest-name references retain those candidates without
                # guessing which caller condition was true.
                needle = '"' + leaf + '"'
                for candidates in by_name.values():
                    for path in candidates:
                        for number, line in enumerate(path.read_text().splitlines(), 1):
                            if needle in line and ('Run(' in line or 'case ' in line):
                                literal_cache[leaf].append(context(path, number, root))
            literal_sites = literal_cache[leaf]
        external_condition = None
        if package == 'crypto/tls' and test and test.startswith('TestBogoSuite/') and not sites:
            if bogo_binding is None:
                fixture_record = summary['fixtures']['manifest']
                fixtures.require(fixtures.record(fixture_record['path']) == fixture_record, 'native fixture manifest changed')
                fixture_manifest = json.loads(Path(fixture_record['path']).read_text())
                matches = [m for m in fixture_manifest['modules'] if m['module'] == 'boringssl.googlesource.com/boringssl.git']
                fixtures.require(len(matches) == 1, 'BoringSSL fixture missing from native evidence')
                module = matches[0]
                module_root = Path(module['result']['Dir'])
                module_source = module_root / 'ssl/test/runner/runner.go'
                expected = [r for r in module['files'] if r['path'] == 'ssl/test/runner/runner.go']
                fixtures.require(len(expected) == 1 and fixtures.sha(module_source) == expected[0]['sha256'], 'BoringSSL source binding changed')
                wrapper = root / 'src/crypto/tls/bogo_shim_test.go'
                wrapper_lines = wrapper.read_text().splitlines()
                module_lines = module_source.read_text().splitlines()
                wrapper_line = next(i for i, line in enumerate(wrapper_lines, 1) if 'if result.Actual == "SKIP"' in line)
                module_line = next(i for i, line in enumerate(module_lines, 1) if 'if msg.err == errUnimplemented' in line)
                external_source = context(module_source, module_line, module_root)
                external_source['fixture_relative_path'] = external_source.pop('sdk_relative_path')
                bogo_binding = {'condition': 'native BoringSSL result.Actual == "SKIP"; upstream runner maps errUnimplemented to SKIP',
                                'wrapper': context(wrapper, wrapper_line, root), 'fixture_source': external_source,
                                'module': module['module'], 'version': module['version'],
                                'limitation': 'The temporary BoringSSL results.json was removed by upstream cleanup; individual native skip terminals and authenticated mapping code are retained.'}
            external_condition = bogo_binding
            category = 'upstream-boringssl-unimplemented-result'
            reason = 'result.Actual == "SKIP"'
        bound = test is None or bool(declarations) or any(s['source_bindings'] for s in sites) or bool(literal_sites)
        fixtures.require(bound, 'skip has no source binding: ' + package + ':' + str(test))
        rows.append({'id': package + (':' + test if test else ''), 'package': package, 'test': test,
                     'category': category, 'exact_reason_candidate': reason, 'terminal_evidence': terminal,
                     'output_evidence': messages, 'positioned_outputs': sites, 'test_declarations': declarations,
                     'external_result_condition': external_condition, 'literal_subtest_candidates': literal_sites, 'native_environment': summary['native_stage']['environment'],
                     'source_bound': bound, 'product_execution_credit': 0,
                     'adjudication': 'upstream-observed-skip; source and native environment retained; no product exclusion granted'})
    package_skips = sum(row['test'] is None for row in rows)
    expected = summary['counts_by_axis']['package'].get('skip', 0)
    fixtures.require(package_skips == expected, 'package skip denominator mismatch')
    result = {'schema': 'bridge-skip-review/v1', 'native_summary': fixtures.record(native / 'summary.json'),
              'native_stdout': log, 'sdk': identity, 'observed_skip_events': len(rows),
              'package_skips': package_skips, 'runtime_test_skips': len(rows) - package_skips,
              'categories': dict(collections.Counter(row['category'] for row in rows)),
              'source_bound_skips': sum(row['source_bound'] for row in rows), 'product_execution_claim': False,
              'product_execution_credit': 0, 'native_environment': summary['native_stage']['environment'],
              'scope': 'all observed upstream skip terminals; candidates retain exact source conditions for independent applicability review'}
    output.mkdir(parents=True)
    if package_skips:
        packages = [row['package'] for row in rows if row['test'] is None]
        env = dict(summary['native_stage']['environment'])
        env['GOROOT'] = identity['root']
        env['PATH'] = identity['root'] + '/bin:/usr/bin:/bin'
        stage = fixtures.capture([identity['root'] + '/bin/go', 'list', '-json', *packages], root, env, output / 'package-selection')
        content = Path(stage['stdout']['path']).read_text()
        decoder = json.JSONDecoder()
        selected = {}
        while content.strip():
            obj, end = decoder.raw_decode(content.lstrip())
            content = content.lstrip()[end:]
            fixtures.require(obj['ImportPath'] not in selected, 'duplicate go-list package')
            selected[obj['ImportPath']] = obj
        fixtures.require(set(selected) == set(packages), 'go-list package selection denominator mismatch')
        for row in rows:
            if row['test'] is not None:
                continue
            selection = selected[row['package']]
            fixtures.require(not selection.get('TestGoFiles') and not selection.get('XTestGoFiles'), 'no-test skip disagrees with host selection')
            files = sorted(set(name for field in ('GoFiles', 'CgoFiles', 'IgnoredGoFiles') for name in selection.get(field, [])))
            row['host_package_selection'] = selection
            row['selection_sources'] = [fixtures.record(root / 'src' / row['package'] / name) for name in files]
        result['host_package_selection_stage'] = stage
    (output / 'roots.jsonl').write_text(''.join(json.dumps(row, sort_keys=True) + '\n' for row in rows))
    (output / 'summary.json').write_text(json.dumps(result, indent=2, sort_keys=True) + '\n')
    print(json.dumps(result, sort_keys=True))


if __name__ == '__main__':
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--native', required=True, type=Path)
    p.add_argument('--sdk-identity', required=True, type=Path)
    p.add_argument('--output', required=True, type=Path)
    args = p.parse_args()
    try:
        report(args.native, args.sdk_identity, args.output)
    except (OSError, ValueError, KeyError) as error:
        sys.exit('FATAL: ' + str(error))
