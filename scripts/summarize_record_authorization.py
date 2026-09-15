#!/usr/bin/env python3
"""Produce a reviewable result only from complete passing normal and mutation runs."""
import collections
import datetime
import hashlib
import json
from pathlib import Path
import runpy
import subprocess

ROOT = Path(__file__).resolve().parents[1]
RAW = ROOT / 'reports/raw/record-authorization'


def read(path):
    return json.loads(path.read_text())


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


profiles = []
for mode in ['can', 'capabilities']:
    for redis in ['false', 'true']:
        directory = RAW / f'{mode}-{redis}'
        suites = [read(directory / name) for name in ['results.json', 'existing-results.json']]
        assert suites[0]['summary']['example_count'] >= 70, 'Incomplete per-record suite'
        assert suites[1]['summary']['example_count'] >= 20, 'Incomplete existing boundary suite'
        for suite in suites:
            assert suite['summary']['failure_count'] == 0 and suite['summary']['pending_count'] == 0
            assert all(e['status'] == 'passed' for e in suite['examples'])
        ledger = [json.loads(line) for line in (directory / 'requests.jsonl').read_text().splitlines()]
        assert ledger and all(r['mode'] == mode and r['redis'] == redis for r in ledger)
        assert all(r['status'] in ['200', '403', '503'] for r in ledger), 'Unexpected transport or HTTP failure'
        routes = sorted(directory.glob('routes-*.json'))
        assert len(routes) == 6, 'Incomplete service route inventory'
        profiles.append({'mode': mode, 'redis': redis == 'true',
                         'examples': sum(s['summary']['example_count'] for s in suites),
                         'record_examples': suites[0]['summary']['example_count'],
                         'existing_examples': suites[1]['summary']['example_count'],
                         'requests': len(ledger), 'http_statuses': dict(collections.Counter(r['status'] for r in ledger)),
                         'service_requests': dict(collections.Counter(r['service'] for r in ledger)),
                         'hashes': {str(p.relative_to(ROOT)): digest(p) for p in routes + [directory / n for n in ['results.json', 'existing-results.json', 'requests.jsonl']]}})
mutant_definitions = runpy.run_path(str(ROOT / 'scripts/test_record_authorization_mutations.py'))['MUTANTS']
mutations = []
for mode in ['can', 'capabilities']:
    records = read(RAW / 'mutations' / mode / 'summary.json')
    expected = {m[0] for m in mutant_definitions if mode == 'can' or not m[0].startswith('internal_')}
    assert {m['mutation'] for m in records} == expected, 'Missing deliberate defects'
    assert len(records) == len(expected)
    assert all(m['mode'] == mode and m['caught'] and m['restored_passed'] for m in records)
    for record in records:
        directory = RAW / 'mutations' / mode / record['mutation']
        paths = [directory / name for name in ['results.json', 'requests.jsonl', 'restored/results.json', 'restored/requests.jsonl']]
        record['hashes'] = {str(p.relative_to(ROOT)): digest(p) for p in paths}
    mutations.extend(records)
sources = []
for service in ROOT.glob('*-service'):
    for directory in ['app', 'lib', 'config']:
        sources.extend((service / directory).rglob('*.rb'))
    sources.extend(p for p in [service / 'Gemfile', service / 'Gemfile.lock'] if p.exists())
sources.extend((ROOT / 'test/integration').glob('*authorization*.rb'))
sources.extend((ROOT / 'scripts').glob('*record_authorization*'))
summary = {'created_at': datetime.datetime.now(datetime.timezone.utc).isoformat(),
           'revision': subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip(),
           'profiles': profiles, 'mutations': mutations,
           'source_sha256': {str(p.relative_to(ROOT)): digest(p) for p in sorted(set(sources)) if p.is_file()},
           'limits': ['Fixed persisted fixture graph; immediate revocation during cache TTL is not asserted.',
                      'Caller identity/trusted-token authentication at an external boundary is outside this record authorization contract.']}
output = ROOT / 'reports/authorization-correctness/record-proof-results.json'
output.write_text(json.dumps(summary, indent=2) + '\n')
report = ROOT / 'reports/authorization-correctness/record-proof.md'
text = report.read_text().split('## Results')[0]
text += '## Results\n\n'
text += f"Verified revision `{summary['revision'][:7]}`. All {sum(p['examples'] for p in profiles)} examples passed across four normal profiles. All {len(mutations)} deliberate-defect runs were detected, and each selected test passed again after restoring its source.\n\n"
text += '| Mode | Redis | Per-record examples | Existing boundary examples | HTTP requests |\n| --- | --- | ---: | ---: | ---: |\n'
for p in profiles:
    text += f"| {p['mode']} | {'enabled, cold then warm' if p['redis'] else 'disabled'} | {p['record_examples']} | {p['existing_examples']} | {p['requests']} |\n"
text += '\n[Machine-readable results and source hashes](record-proof-results.json). [Local raw evidence](../raw/record-authorization/) contains HTTP ledgers, classified routes, and normal/mutated/restored test reports. Raw artifacts are gitignored; their hashes are preserved in the committed summary.\n'
text += '\nThe new tests exposed missing actor propagation in the GraphQL organization-count source, generic errors for denied count/context requests, and incomplete slow HTML rendering. The fixes preserve the real actor and the existing authorization rules.\n'
report.write_text(text)
print(json.dumps({'examples': sum(p['examples'] for p in profiles), 'requests': sum(p['requests'] for p in profiles), 'mutations_caught_and_restored': len(mutations)}))
