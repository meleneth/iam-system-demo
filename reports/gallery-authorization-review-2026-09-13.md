# Gallery authorization review — September 13, 2026

Completed on repaired prod, without reseeding, performance tuning, or publication. **12 of 13 measured requests passed exact-record checks; one measured request failed at transport.** All **182 boundary checks (26 in each of seven profiles)** passed. All 13 trace exports passed HTTP/API ancestry, SQL, and cache validation.

This is a working-tree correctness review, not the full benchmark suite or publication evidence. Existing benchmark files and published gallery assets were left unchanged. The source patch, untracked runtime/collector files, file hashes, image IDs, runtime configuration, and fixture manifest are retained in the collection.

## Review the traces

Links open the local prod Jaeger viewer; archived JSON remains available if Jaeger expires a trace. Each request directory also contains its result and returned body (hierarchy requests retain per-request evidence). Times are single observations, not statistical performance claims.

| Example | Decision/identity check | Client seconds | SQL spans | Trace |
| --- | --- | ---: | ---: | --- |
| hierarchy-walk | passed | 0.115526 | 30 | [Viewer](http://localhost:11290/trace/e49858ab1c06f94a2f2b3b25e6586459) · [JSON](raw/gallery-auth-correctness-20260913/hierarchies-redis-off/attempt-001/hierarchy-walk/trace.json) |
| hierarchy-cte | passed | 0.050380 | 13 | [Viewer](http://localhost:11290/trace/24f3c53222fd7ae738f0cea3cc22460f) · [JSON](raw/gallery-auth-correctness-20260913/hierarchies-redis-off/attempt-001/hierarchy-cte/trace.json) |
| hierarchy-individual | passed | 0.504813 | 104 | [Viewer](http://localhost:11290/trace/2da262eeda1a65434967e29620bf8998) · [JSON](raw/gallery-auth-correctness-20260913/hierarchies-redis-off/attempt-001/hierarchy-individual/trace.json) |
| hierarchy-batch | passed | 0.087441 | 13 | [Viewer](http://localhost:11290/trace/7bf74020a55c7276f8ce8330238c101f) · [JSON](raw/gallery-auth-correctness-20260913/hierarchies-redis-off/attempt-001/hierarchy-batch/trace.json) |
| authorization-record-can | passed | 0.650456 | 150 | [Viewer](http://localhost:11290/trace/b590cfdaa1f381ca0da39b6d261d1a86) · [JSON](raw/gallery-auth-correctness-20260913/hierarchies-redis-off/attempt-001/authorization-record-can/trace.json) |
| authorization-record-capabilities | passed | 13.827702 | 3977 | [Viewer](http://localhost:11290/trace/8300897afa2f04193dd17bb2cddedc84) · [JSON](raw/gallery-auth-correctness-20260913/retrieval-deep-serial/attempt-001/authorization-record-capabilities/trace.json) |
| authorization-collection-capabilities | empty reply; unverified | 30.012983 | 8072 | [Viewer](http://localhost:11290/trace/b88ec6eedcdef80420aa8a44f8410fde) · [JSON](raw/gallery-auth-correctness-20260913/retrieval-wide-batched/attempt-001/authorization-collection-capabilities/trace.json) |
| authorization-collection-can | passed | 1.839051 | 64 | [Viewer](http://localhost:11290/trace/ea76f99e91d7d24cb5841aa0f7dd090f) · [JSON](raw/gallery-auth-correctness-20260913/auth-wide-can/attempt-001/authorization-collection-can/trace.json) |
| organization-cold | passed | 1.103546 | 26 | [Viewer](http://localhost:11290/trace/bc3068061a13ec2acf144e0f7314ca0c) · [JSON](raw/gallery-auth-correctness-20260913/cache-wide-can/attempt-001/organization-cold/trace.json) |
| organization-warm | passed | 0.979194 | 19 | [Viewer](http://localhost:11290/trace/a443bd8909795716ffc2964a558cb5a6) · [JSON](raw/gallery-auth-correctness-20260913/cache-wide-can/attempt-001/organization-warm/trace.json) |
| graphql-cold | passed | 0.225673 | 16 | [Viewer](http://localhost:11290/trace/d73d2bdeb5ab2c6421c9724a7a685f71) · [JSON](raw/gallery-auth-correctness-20260913/graphql-cache-b1000/attempt-001/graphql-cold/trace.json) |
| graphql-warm | passed | 0.155071 | 5 | [Viewer](http://localhost:11290/trace/788454b6d9ce4d31a6ffaf19f1f9f450) · [JSON](raw/gallery-auth-correctness-20260913/graphql-cache-b1000/attempt-001/graphql-warm/trace.json) |
| graphql-msp | passed | 0.651709 | 11 | [Viewer](http://localhost:11290/trace/d3c0e6474a166a25d909dad8ed0f5cc4) · [JSON](raw/gallery-auth-correctness-20260913/graphql-cache-b200/attempt-001/graphql-msp/trace.json) |

## What the correctness checks prove

Every profile passed paired legitimate Account allows and unrelated fixture denials, mixed Organization list denials, MSP-owned client allows and cross-MSP denials, repeated requests, and the known out-of-branch leaf denial. Expected scopes come from the seed manifest, independently of the authorization responses.

Hierarchy measurements compare exact IDs and parent chains. Organization and GraphQL responses additionally compare deterministic fixture Account IDs, parent links, User IDs and account scopes, and exact Group IDs/names per user. Available Organization/MSP totals, actor/organization identity, and MSP cursor are checked. This covers every returned record in these selected responses; it does not constitute a full pagination walk or a system-wide security claim.

For the MSP sample, the checked first page contains exactly the first 200 sorted client Account IDs from the 9,999-client ownership fixture, the corresponding users/groups, total 9,999, loaded count 200, and cursor "200". The measured warm trace includes cached authorization. Inspect the [first MSP warmup trace](raw/gallery-auth-correctness-20260913/graphql-cache-b200/attempt-001/warmup-1/trace.json) for the cold authority computation after Redis was cleared.

## Failure retained

The wide batched capabilities measurement returned curl 52 (empty reply, no HTTP status) after **30.012983 seconds**. Both preceding warmups returned the exact expected 251 accounts, 5,020 users, and group memberships, but they do not validate the missing measured response. Its trace and service diagnostics are retained. The collection correctly exited 1. No retry or timeout/performance adjustment was used to replace this observation.

## Reproducibility and status

Collector validation: 42 repository harness tests, 244 assertions, zero failures/errors, including four validator tests that pair a legitimate allow with same-count foreign account/group substitutions and incorrect totals. The full service/integration suite was not rerun in this turn.

Final prod profile: `/can`, Redis enabled, batched retrieval, batch size 200. No seed workers ran and no database restart/reseed was requested by this collection. Only dedicated Redis DB 1 was flushed for cold cases. Rails process identities remained stable between profile warmups and measurements.

[Collection status](raw/gallery-auth-correctness-20260913/collection_status.json) · [Trace index](raw/gallery-auth-correctness-20260913/trace-index.json) · [Trace validation](raw/gallery-auth-correctness-20260913/reduced-trace-validation.json) · [Collector tests](raw/gallery-auth-correctness-20260913/collector-tests.txt)

Full-suite execution, article-scale reruns, and publication remain deferred.
