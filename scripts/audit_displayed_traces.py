"""Audit the whirred.io trace selection, without reading the large source traces.

python3 scripts/audit_displayed_traces.py --site-root ~/Documents/whirred-io --output-dir reports/summary
"""
import argparse
from collections import defaultdict
from hashlib import sha256
import json
from pathlib import Path

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--site-root', type=Path, required=True)
parser.add_argument('--output-dir', type=Path, required=True)
parser.add_argument('--demo-root', type=Path, default=Path(__file__).resolve().parents[1])
args = parser.parse_args()
site = args.site_root.expanduser()
manifest = json.loads((site / 'docs/public/traces/iam/manifest.json').read_text())
report = {'thresholds': {'http_gap_us': 10000, 'uncovered_us': 10000, 'uncovered_fraction': 0.5}, 'examples': []}
for entry in manifest:
    raw = (site / ('docs/public' + entry['file'])).read_bytes()
    assert sha256(raw).hexdigest() == entry['sha256'], entry['id']
    sidecar_path = args.demo_root.expanduser() / 'reports/raw' / entry['source']
    sidecar_path = sidecar_path.with_suffix('.status.json')
    sidecar = json.loads(sidecar_path.read_text())
    trace = json.loads(raw)['data'][0]
    assert sidecar['trace_id'] == trace['traceID']
    spans = trace['spans']
    by_id = {s['spanID']: s for s in spans}
    assert len(by_id) == len(spans) == entry['spans']
    children = defaultdict(list)
    tags = {s['spanID']: {t['key']: t['value'] for t in s.get('tags', [])} for s in spans}
    def info(s):
        t = tags[s['spanID']]
        return {'span_id': s['spanID'], 'operation': s['operationName'],
                'service': trace['processes'][s['processID']]['serviceName'],
                'http_host': t.get('http.host'), 'http_url': t.get('http.url'),
                'http_target': t.get('http.target'), 'duration_us': s['duration'],
                'start_us': s['startTime'], 'end_us': s['startTime'] + s['duration']}
    missing, containment, warnings, cycles = [], [], [], []
    for span in spans:
        if span.get('warnings'): warnings.append({'span_id': span['spanID'], 'warnings': span['warnings']})
        for ref in span.get('references', []):
            if ref['refType'] != 'CHILD_OF': continue
            if ref['traceID'] != trace['traceID'] or ref['spanID'] not in by_id:
                missing.append({'span_id': span['spanID'], 'reference': ref,
                                'expected_excerpt_boundary': entry['kind'] == 'subtree' and span['spanID'] == entry['rootSpanID'],
                                'expected_harness_parent': ref['spanID'] == sidecar['initiating_span_id']})
                continue
            parent = by_id[ref['spanID']]
            children[parent['spanID']].append(span)
            early = max(0, parent['startTime'] - span['startTime'])
            late = max(0, span['startTime'] + span['duration'] - parent['startTime'] - parent['duration'])
            if early or late: containment.append({'parent': parent['spanID'], 'child': span['spanID'], 'early_us': early, 'late_us': late})
    for span in spans:
        seen = {span['spanID']}; current = span
        while True:
            ref = next((r for r in current.get('references', []) if r['refType'] == 'CHILD_OF' and r['traceID'] == trace['traceID']), None)
            if not ref or ref['spanID'] not in by_id: break
            if ref['spanID'] in seen:
                cycles.append(span['spanID']); break
            seen.add(ref['spanID']); current = by_id[ref['spanID']]
    pairs, unpaired, uncovered = [], [], []
    for span in spans:
        child_spans = children[span['spanID']]
        t = tags[span['spanID']]
        if t.get('span.kind') == 'client' and 'http.method' in t:
            servers = [s for s in child_spans if tags[s['spanID']].get('span.kind') == 'server']
            if not servers: unpaired.append(info(span))
            for server in servers:
                lead = server['startTime'] - span['startTime']
                tail = span['startTime'] + span['duration'] - server['startTime'] - server['duration']
                pairs.append({'client': info(span), 'server': info(server), 'pre_server_us': lead, 'post_server_us': tail,
                              'flagged': lead >= 10000 or tail >= 10000})
        # Union, not sum: siblings can overlap. Clip to parent interval.
        start, end = span['startTime'], span['startTime'] + span['duration']
        intervals = sorted((max(start, s['startTime']), min(end, s['startTime'] + s['duration'])) for s in child_spans)
        cursor = start; gaps = []
        for left, right in intervals:
            if right <= left: continue
            if left > cursor: gaps.append((cursor, left))
            cursor = max(cursor, right)
        if cursor < end: gaps.append((cursor, end))
        total = sum(right-left for left, right in gaps)
        if t.get('span.kind') != 'client' and total >= 10000 and total >= span['duration'] * .5:
            parent_ref = next((r for r in span.get('references', []) if r['refType'] == 'CHILD_OF' and r['traceID'] == trace['traceID']), None)
            siblings = children[parent_ref['spanID']] if parent_ref else []
            overlaps = sorted((max(left, sibling['startTime']), min(right, sibling['startTime'] + sibling['duration']))
                              for left, right in gaps for sibling in siblings if sibling['spanID'] != span['spanID'])
            covered_by_siblings = 0; cursor = start
            for left, right in overlaps:
                if right <= left: continue
                covered_by_siblings += max(0, right - max(cursor, left)); cursor = max(cursor, right)
            uncovered.append({**info(span), 'uncovered_but_overlapping_siblings_us': covered_by_siblings, 'direct_children': len(child_spans), 'uncovered_us': total,
                              'fraction': total / span['duration'], 'largest_gap_us': max(right-left for left, right in gaps)})
    item = {'id': entry['id'], 'trace_id': entry['traceID'], 'source': entry['source'], 'sha256': entry['sha256'],
            'kind': entry['kind'], 'span_count': len(spans), 'source_span_count': entry['sourceSpans'],
            'http_pairs': pairs, 'unpaired_http_clients': unpaired, 'uncovered_nonclient_spans': uncovered,
            'missing_parent_references': missing, 'containment_violations': containment, 'cycles': cycles,
            'archive_status': sidecar, 'span_warnings': warnings, 'trace_warnings': trace.get('warnings')}
    report['examples'].append(item)
all_pairs = [p for e in report['examples'] for p in e['http_pairs']]
report['totals'] = {'examples': len(manifest), 'spans': sum(e['span_count'] for e in report['examples']),
                    'http_pairs': len(all_pairs), 'pre_server_10ms': sum(p['pre_server_us'] >= 10000 for p in all_pairs),
                    'post_server_10ms': sum(p['post_server_us'] >= 10000 for p in all_pairs),
                    'unpaired_http_clients': sum(len(e['unpaired_http_clients']) for e in report['examples']),
                    'uncovered_nonclient_spans': sum(len(e['uncovered_nonclient_spans']) for e in report['examples']),
                    'containment_violations': sum(len(e['containment_violations']) for e in report['examples']),
                    'unexpected_missing_parents': sum(not (r['expected_excerpt_boundary'] or r['expected_harness_parent']) for e in report['examples'] for r in e['missing_parent_references']),
                    'expected_harness_parent_references': sum(r['expected_harness_parent'] for e in report['examples'] for r in e['missing_parent_references']),
                    'expected_excerpt_parent_references': sum(r['expected_excerpt_boundary'] for e in report['examples'] for r in e['missing_parent_references']),
                    'cycles': sum(len(e['cycles']) for e in report['examples'])}
args.output_dir.mkdir(parents=True, exist_ok=True)
out = args.output_dir / 'displayed-trace-gap-audit-2026-09-10.json'
out.write_text(json.dumps(report, indent=2) + '\n')
print(json.dumps(report['totals'], indent=2))
print('EXAMPLES: id / spans / pairs / pre >=10ms / post >=10ms / max pre ms / max post ms / uncovered nonclients')
for e in report['examples']:
    ps=e['http_pairs'];print(e['id'],e['span_count'],len(ps),sum(p['pre_server_us']>=10000 for p in ps),sum(p['post_server_us']>=10000 for p in ps),round(max([p['pre_server_us'] for p in ps]+[0])/1000,3),round(max([p['post_server_us'] for p in ps]+[0])/1000,3),len(e['uncovered_nonclient_spans']))
