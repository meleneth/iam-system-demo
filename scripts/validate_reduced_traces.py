#!/usr/bin/env python3
"""Validate warmed showcase traces: HTTP/API calls, application SQL, and Redis remain."""
import collections
import json
from pathlib import Path
import re
import sys

collection = Path(sys.argv[1]).resolve()
entries = json.loads((collection / 'trace-index.json').read_text())
forbidden = re.compile(r'^connect$|HTTP CONNECT|http\.(?:connection|request\.write|response\.)|rack\.response|Controller#|materializ|serializ|\.encode|\.decode|payload\.build|params\.parse', re.I)
results = []
for entry in entries:
    path = Path(entry['output'])
    trace, = json.loads(path.read_text())['data']
    spans = trace['spans']
    assert entry['status'] == 'archived', entry['id']
    assert trace['traceID'] == entry['trace_id'], entry['id']
    by_id = {span['spanID']: span for span in spans}
    assert len(by_id) == len(spans)
    cross_service = 0
    external = set()
    redis = 0
    http_clients = 0
    api_servers = 0
    sql_queries = 0
    for span in spans:
        name = span['operationName']
        tags = {tag['key']: tag['value'] for tag in span.get('tags', [])}
        assert not forbidden.search(name), (entry['id'], name)
        assert tags.get('otel.scope.name', tags.get('otel.library.name')) not in {
            'OpenTelemetry::Instrumentation::ActionPack',
            'OpenTelemetry::Instrumentation::ActionView', 'OpenTelemetry::Instrumentation::Faraday',
            'OpenTelemetry::Instrumentation::PG', 'OpenTelemetry::Instrumentation::ActiveRecord',
        }, (entry['id'], tags)
        assert tags.get('db.system') != 'redis' or not forbidden.search(name)
        redis += tags.get('db.system') == 'redis'
        http_clients += tags.get('otel.scope.name') == 'OpenTelemetry::Instrumentation::Net::HTTP'
        api_servers += tags.get('span.kind') == 'server'
        if tags.get('db.system') == 'postgresql':
            sql_queries += 1
            assert tags.get('otel.scope.name') == 'iam.application_sql', (entry['id'], tags)
            assert tags.get('db.query.name') not in ('SCHEMA', 'TRANSACTION')
            assert re.match(r'\s*(SELECT|INSERT|UPDATE|DELETE|WITH)\b', tags['db.statement'], re.I)
            assert not re.search(r'\b(pg_catalog|information_schema|pg_attribute|pg_class|pg_type)\b', tags['db.statement'], re.I)
            ancestor = span
            seen = set()
            while ancestor['spanID'] not in seen:
                seen.add(ancestor['spanID'])
                parent = next((ref['spanID'] for ref in ancestor.get('references', []) if ref['refType'] == 'CHILD_OF'), None)
                ancestor = by_id.get(parent)
                assert ancestor, (entry['id'], 'SQL outside API call', span['spanID'])
                attrs = {t['key']: t['value'] for t in ancestor.get('tags', [])}
                if attrs.get('span.kind') == 'server':
                    assert ancestor['processID'] == span['processID']
                    break
            else:
                raise AssertionError('Cyclic SQL ancestry')
        parents = [ref for ref in span.get('references', []) if ref['refType'] == 'CHILD_OF']
        assert parents, (entry['id'], 'parentless span', span['spanID'])
        for ref in parents:
            assert ref['traceID'] == trace['traceID'], (entry['id'], 'foreign trace')
            if ref['spanID'] in by_id:
                cross_service += by_id[ref['spanID']]['processID'] != span['processID']
            else:
                external.add(ref['spanID'])
    assert external == {entry['parent_id']}, (entry['id'], external)
    assert http_clients and api_servers and sql_queries, (entry['id'], 'Missing HTTP, API, or SQL spans')
    assert cross_service > 0, (entry['id'], 'no cross-service ancestry')
    names = collections.Counter(span['operationName'] for span in spans)
    results.append(dict(id=entry['id'], trace_id=trace['traceID'], spans=len(spans),
        outcome=entry.get('request_outcome', 'ok'), cross_service_parent_links=cross_service,
        http_client_spans=http_clients, api_server_spans=api_servers, sql_queries=sql_queries, redis_spans=redis, application_cache_spans=sum(count for name, count in names.items() if '.cache.' in name),
        envelope_seconds=(max(s['startTime'] + s['duration'] for s in spans) - min(s['startTime'] for s in spans)) / 1e6,
        operation_counts=dict(names)))
assert any(item['redis_spans'] for item in results), 'No Redis spans retained'
assert any(item['application_cache_spans'] for item in results), 'No application cache spans retained'
output = collection / 'reduced-trace-validation.json'
output.write_text(json.dumps(results, indent=2) + '\n')
print(f'Validated {len(results)} exports: HTTP/API ancestry, application SQL, and caches visible; phase/schema/setup timings absent. {output}')
