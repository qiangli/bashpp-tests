#!/usr/bin/env python3
"""Authenticate exact SDK test fixtures, outside the immutable SDK tree."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
sys.dont_write_bytecode = True

HERE = Path(__file__).resolve().parent
SPECS = [
    ('github.com/c2sp/wycheproof', 'crypto/internal/cryptotest/wycheproof/schemaversion.go', r'const wycheproofVersion = "([^"]+)"', 'crypto/internal/cryptotest/wycheproof/_schema/go.sum'),
    ('filippo.io/mostly-harmless/ed25519vectors', 'crypto/ed25519/ed25519vectors_test.go', r'version := "([^"]+)"', None),
    ('boringssl.googlesource.com/boringssl.git', 'crypto/tls/bogo_shim_test.go', r'const boringsslModVer = "([^"]+)"', None),
    ('github.com/C2SP/x509-limbo', 'crypto/internal/cryptotest/x509limbo/schemaversion.go', r'const X509LimboVersion = "([^"]+)"', None),
    ('golang.org/x/tools', 'runtime/_mkmalloc/go.mod', r'require golang.org/x/tools (\S+)', 'runtime/_mkmalloc/go.sum'),
]


def require(condition, message):
    if not condition:
        raise ValueError(message)


def sha(path):
    h = hashlib.sha256()
    with Path(path).open('rb') as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b''):
            h.update(block)
    return h.hexdigest()


def record(path):
    path = Path(path)
    return {'path': str(path), 'bytes': path.stat().st_size, 'sha256': sha(path)}


def tree(path):
    root = Path(path)
    rows = []
    for p in sorted(root.rglob('*')):
        require(not p.is_symlink(), 'fixture tree contains symlink: ' + str(p))
        if p.is_file():
            rows.append({'path': p.relative_to(root).as_posix(), 'bytes': p.stat().st_size, 'sha256': sha(p)})
    return rows


def sdk(identity_path):
    identity = json.loads(Path(identity_path).read_text())
    require(identity['schema'] == 'go-full-sdk/v1', 'unknown SDK schema')
    argv = [sys.executable, str(HERE.parent / 'go-full/sdk.py'), '--source-cache', str(Path(identity['source_archive']['path']).parent), '--cache', str(Path(identity['distribution_archive']['path']).parent), '--output', identity['root'], '--goos', identity['goos'], '--goarch', identity['goarch']]
    result = subprocess.run(argv, capture_output=True, text=True, check=True)
    require(json.loads(result.stdout) == identity, 'SDK identity reauthentication mismatch')
    return identity


def specifications(identity):
    root = Path(identity['root']) / 'src'
    rows = []
    for module, rel, regex, sumrel in SPECS:
        source = root / rel
        matches = list(re.finditer(regex, source.read_text()))
        require(len(matches) == 1, 'expected exactly one fixture version: ' + rel)
        match = matches[0]
        version = match.group(1)
        row = {'module': module, 'version': version, 'binding': record(source), 'line': source.read_text()[:match.start()].count('\n') + 1, 'sdk_sums': {}}
        if sumrel:
            row['sum_binding'] = record(root / sumrel)
            for line in (root / sumrel).read_text().splitlines():
                name, v, digest = line.split()
                if name == module and v in (version, version + '/go.mod'):
                    row['sdk_sums']['GoModSum' if v.endswith('/go.mod') else 'Sum'] = digest
            require(set(row['sdk_sums']) == {'Sum', 'GoModSum'}, 'SDK go.sum lacks exact module checksums')
        rows.append(row)
    return rows


def environment(identity, destination, network):
    return {'PATH': identity['root'] + '/bin:/usr/bin:/bin', 'GOROOT': identity['root'], 'GOTOOLCHAIN': 'local', 'GOENV': 'off', 'GOFLAGS': '', 'GOWORK': 'off', 'GOMAXPROCS': '4', 'GOPROXY': 'https://proxy.golang.org' if network else 'off', 'GOSUMDB': 'sum.golang.org' if network else 'off', 'GONOSUMDB': '', 'GOPRIVATE': '', 'GONOPROXY': '', 'HOME': str(destination / 'home'), 'GOPATH': str(destination / 'gopath'), 'GOMODCACHE': str(destination / 'gomodcache'), 'GOCACHE': str(destination / 'gocache'), 'TMPDIR': str(destination / 'tmp'), 'LC_ALL': 'C', 'TZ': 'UTC'}


def capture(argv, cwd, env, prefix):
    original = prefix
    attempt = 1
    while Path(str(prefix) + '.stdout').exists():
        attempt += 1
        prefix = Path(str(original) + '-attempt' + str(attempt))
    with Path(str(prefix) + '.stdout').open('wb') as out, Path(str(prefix) + '.stderr').open('wb') as err:
        result = subprocess.run(argv, cwd=cwd, env=env, stdout=out, stderr=err, timeout=900)
    stage = {'argv': argv, 'cwd': str(cwd), 'environment': env, 'exit': result.returncode, 'stdout': record(str(prefix) + '.stdout'), 'stderr': record(str(prefix) + '.stderr')}
    Path(str(prefix) + '.stage.json').write_text(json.dumps(stage, indent=2, sort_keys=True) + '\n')
    require(result.returncode == 0, 'fixture command failed; inspect ' + str(prefix))
    return stage


def provision(identity_path, destination, resume=False):
    identity = sdk(identity_path)
    specs = specifications(identity)
    require(not destination.exists() or (resume and not (destination / 'manifest.json').exists()), 'fixture destination already complete or resume not requested')
    destination.mkdir(parents=True, exist_ok=True)
    env = environment(identity, destination, True)
    for key in ('HOME', 'GOPATH', 'GOMODCACHE', 'GOCACHE', 'TMPDIR'):
        Path(env[key]).mkdir(parents=True, exist_ok=True)
    work = destination / 'module'
    work.mkdir(exist_ok=resume)
    (work / 'go.mod').write_text('module sprint118.fixturecache\n\ngo 1.27.0\n\nrequire (\n' + ''.join('\t' + row['module'] + ' ' + row['version'] + '\n' for row in specs) + ')\n')
    (work / 'go.sum').write_text(''.join(row['module'] + ' ' + row['version'] + ('/go.mod' if key == 'GoModSum' else '') + ' ' + value + '\n' for row in specs for key, value in row['sdk_sums'].items()))
    manifest = {'schema': 'bridge-fixtures/v1', 'sdk_manifest_sha256': identity['manifest_sha256'], 'sdk_identity': record(identity_path), 'gomodcache': env['GOMODCACHE'], 'module': str(work), 'modules': [], 'product_execution_claim': False}
    for i, spec in enumerate(specs):
        stage = capture([identity['root'] + '/bin/go', 'mod', 'download', '-json', spec['module'] + '@' + spec['version']], work, env, destination / ('download-%02d' % i))
        result = json.loads(Path(stage['stdout']['path']).read_text())
        require((result.get('Path'), result.get('Version')) == (spec['module'], spec['version']) and not result.get('Error'), 'download identity mismatch')
        for key in ('Sum', 'GoModSum'):
            require(re.fullmatch(r'h1:[A-Za-z0-9+/]{43}=', result.get(key, '')) is not None, 'missing authenticated module sum')
        for key, value in spec['sdk_sums'].items():
            require(result[key] == value, 'SDK module checksum mismatch')
        manifest['modules'].append(dict(spec, download=stage, result=result, archive=record(result['Zip']), gomod=record(result['GoMod']), files=tree(result['Dir']), authentication='SDK go.sum and sum.golang.org' if spec['sdk_sums'] else 'SDK version; sum.golang.org checksum verification'))
        print('Authenticated ' + spec['module'] + '@' + spec['version'], flush=True)
    manifest['graph_stage'] = capture([identity['root'] + '/bin/go', 'mod', 'download', '-json', 'all'], work, env, destination / 'download-graph')
    content = Path(manifest['graph_stage']['stdout']['path']).read_text()
    decoder = json.JSONDecoder()
    manifest['dependency_graph'] = []
    while content.strip():
        result, end = decoder.raw_decode(content.lstrip())
        content = content.lstrip()[end:]
        require(not result.get('Error') and result.get('Sum') and result.get('GoModSum'), 'dependency graph download failed')
        manifest['dependency_graph'].append({'result': result, 'archive': record(result['Zip']), 'gomod': record(result['GoMod']), 'files': tree(result['Dir'])})
    manifest['verify_stage'] = capture([identity['root'] + '/bin/go', 'mod', 'verify'], work, environment(identity, destination, False), destination / 'verify')
    manifest['module_files'] = [record(work / name) for name in ('go.mod', 'go.sum')]
    (destination / 'manifest.json').write_text(json.dumps(manifest, indent=2, sort_keys=True) + '\n')
    return {'manifest': record(destination / 'manifest.json'), 'modules': len(specs)}


def check_locked_module(row, locked, cache):
    result = row['result']
    key = (result['Path'], result['Version'])
    require(key in locked, 'module outside reviewed fixture lock')
    pin = locked[key]
    for field in ('Dir', 'Zip', 'GoMod'):
        require(Path(result[field]).resolve().is_relative_to(cache.resolve()), 'fixture path outside declared module cache')
    require(result['Sum'] == pin['sum'] and result['GoModSum'] == pin['gomod_sum'], 'reviewed fixture module sum mismatch')
    require(row['archive']['sha256'] == pin['archive_sha256'] and row['gomod']['sha256'] == pin['gomod_sha256'], 'reviewed fixture artifact checksum mismatch')
    tree_sha = hashlib.sha256(json.dumps(row['files'], sort_keys=True, separators=(',', ':')).encode()).hexdigest()
    require(tree_sha == pin['tree_sha256'], 'reviewed fixture tree manifest mismatch')


def validate(identity_path, manifest_path):
    identity = sdk(identity_path)
    manifest = json.loads(manifest_path.read_text())
    require(manifest['schema'] == 'bridge-fixtures/v1' and manifest['sdk_manifest_sha256'] == identity['manifest_sha256'], 'fixture SDK identity mismatch')
    specs = specifications(identity)
    lock = json.loads((HERE.parent.parent / 'docs/bridge-corpus/fixture-lock.json').read_text())
    require(lock['schema'] == 'bridge-fixture-lock/v1' and lock['sdk_manifest_sha256'] == identity['manifest_sha256'], 'fixture lock SDK mismatch')
    locked = {(row['module'], row['version']): row for row in lock['modules']}
    require(len(locked) == len(lock['modules']), 'duplicate fixture lock module')
    cache = Path(manifest['gomodcache'])
    graph_keys = [(row['result']['Path'], row['result']['Version']) for row in manifest['dependency_graph']]
    require(len(set(graph_keys)) == len(graph_keys) and set(graph_keys) == set(locked), 'fixture graph differs from lock')
    require(len(manifest['modules']) == len(specs), 'fixture module denominator mismatch')
    for spec, row in zip(specs, manifest['modules']):
        check_locked_module(row, locked, cache)
        require(all(row.get(key) == value for key, value in spec.items()), 'fixture source binding drift')
        for key in ('archive', 'gomod'):
            require(record(row[key]['path']) == row[key], 'fixture artifact changed: ' + key)
        require(tree(row['result']['Dir']) == row['files'], 'fixture extracted bytes changed')
        for key, value in spec['sdk_sums'].items():
            require(row['result'][key] == value, 'fixture SDK sum mismatch')
        # The captured Go command authenticated the remaining sums against sumdb.
        require(row['download']['environment']['GOSUMDB'] == 'sum.golang.org' and row['download']['exit'] == 0, 'fixture lacks checksum database authentication')
        require(record(row['download']['stdout']['path']) == row['download']['stdout'], 'fixture download evidence changed')
        require(json.loads(Path(row['download']['stdout']['path']).read_text()) == row['result'], 'fixture result differs from authenticated download')
    for row in manifest['dependency_graph']:
        check_locked_module(row, locked, cache)
        for key in ('archive', 'gomod'):
            require(record(row[key]['path']) == row[key], 'dependency graph artifact changed')
        require(tree(row['result']['Dir']) == row['files'], 'dependency graph extracted bytes changed')
    for row in manifest['module_files']:
        require(record(row['path']) == row, 'fixture module file changed')
    return {'manifest': record(manifest_path), 'gomodcache': manifest['gomodcache'], 'modules': len(specs), 'sdk_manifest_sha256': identity['manifest_sha256'], 'verified': True}


if __name__ == '__main__':
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('action', choices=('provision', 'validate'))
    p.add_argument('--sdk-identity', required=True, type=Path)
    p.add_argument('--path', required=True, type=Path)
    p.add_argument('--resume', action='store_true', help='resume incomplete provisioning, retaining prior command logs')
    a = p.parse_args()
    try:
        print(json.dumps(provision(a.sdk_identity, a.path.resolve(), a.resume) if a.action == 'provision' else validate(a.sdk_identity, a.path.resolve()), sort_keys=True))
    except (OSError, ValueError, KeyError, subprocess.SubprocessError) as error:
        sys.exit('FATAL: ' + str(error))
