# Article benchmark summary — 2026-09-10

All 17 cases completed: both smoke gates and 13 measured cases passed; two measured cases failed. The strongest supported results are fewer hierarchy HTTP requests, faster batched deep retrieval, and substantially faster large MSP walks with Redis. Capabilities mode has workload-specific performance and reliability problems; it did not fail universally.

Collection: [raw evidence](raw/article-no-x-20260910T011818Z/). Source revision: `c4752dcbff5cf99de65ee3bd846563a302289bde`. Collection ran 16:32:34–19:34:59 UTC (3h 02m 25s, including builds, ANALYZE, startup and trace export). Two-million-job seeding took 7h 33m 32s including queue drain; all five queues were empty and all ten workers stopped before collection. ANALYZE completed across all 20 production PostgreSQL services.

Hardware: AMD Ryzen 9 7940HS, 8 cores / 16 threads; Linux reported 60.64 GiB usable RAM, 50.49 GiB available at collection start, and no swap. This is a host-memory snapshot, not peak benchmark RAM usage or DIMM specifications. Graphical session was stopped. Runtime: Ruby 4.0.6, PostgreSQL 18.6, Redis 8.10.1; production service settings and image IDs are saved per attempt.

All tables show seconds as **median [minimum–maximum]**, with three measured repetitions per cell. Speedups are ratios of medians, not medians of paired ratios. Warm-up rows and duplicate per-page rows are excluded from summary timings. MSP and organization walks use the harness’s full-walk total, not just the first page. Those totals sum HTTP request times; they exclude trace polling and any between-request orchestration time.

**Hierarchy traversal and smart APIs.** Redis disabled, actor authorization retained. These are end-to-end requests, not isolated SQL timings.

| Depth | Parent-by-parent GET | Hierarchy GET / CTE | Ratio | Client requests |
| --- | ---: | ---: | ---: | --- |
| 1 | 0.055 [0.041–0.057] | 0.081 [0.055–0.092] | 0.7× | 1 → 1 |
| 5 | 0.190 [0.167–0.210] | 0.069 [0.063–0.074] | 2.7× | 5 → 1 |
| 10 | 0.297 [0.274–0.401] | 0.049 [0.045–0.052] | 6.0× | 10 → 1 |
| 25 | 1.385 [0.582–1.601] | 0.056 [0.046–0.076] | 24.8× | 25 → 1 |

At depth 1 the hierarchy endpoint was slower; the benefit grows with avoided round trips. At depth 25, the median improvement was 24.8×, with substantial variability in the walk. Returned IDs and parent links passed the harness equivalence checks.

| Target set | Individual hierarchy GETs | One batch POST | Ratio | Client requests |
| --- | ---: | ---: | ---: | --- |
| Deep, 8 targets | 0.201 [0.170–0.304] | 0.054 [0.047–0.078] | 3.7× | 8 → 1 |
| Deep, 25 targets | 0.581 [0.556–0.660] | 0.059 [0.033–0.061] | 9.9× | 25 → 1 |
| Wide, 8 targets | 0.257 [0.200–0.281] | 0.073 [0.058–0.135] | 3.5× | 8 → 1 |
| Wide, 251 targets | 7.623 [7.047–10.357] | 0.266 [0.257–0.346] | 28.7× | 251 → 1 |

Caching further reduced depth-25 hierarchy GET median from 0.040s cold to 0.006s warm. This demonstrates application/hierarchy cache effects; “cold” means flushed Redis DB 1, not a cold PostgreSQL buffer cache.

**Retrieval and authorization.** Redis disabled, batch size 1000. Deep: 25 accounts/500 users; wide: 251 accounts/5,020 users; sparse: 401 accounts/8,020 users.

| Workload | Mode | Result | Seconds |
| --- | --- | --- | ---: |
| Deep | Serial, capabilities | 3/3 succeeded | 13.269 [12.315–15.346] |
| Deep | Batched, capabilities | 3/3 succeeded | 1.152 [1.142–1.673] |
| Wide | Serial, capabilities | 3/3 empty HTTP replies | 135.832 [135.280–145.987] to failure |
| Wide | Batched, capabilities | 3/3 succeeded | 27.266 [26.598–27.794] |
| Wide | Batched, /can | 3/3 succeeded | 1.785 [1.782–2.410] |
| Sparse | Batched, capabilities | 3/3 empty HTTP replies | 66.507 [63.751–73.404] to failure |
| Sparse | Batched, /can | 3/3 succeeded | 3.829 [3.755–4.639] |

Deep batching was 11.5× faster than serial retrieval under the same capabilities mode. For the successful wide batched comparison, `/can` was 15.3× faster than capabilities. Both failed cases used capabilities, consistent with the concern about that path, but deep serial, deep batched, and wide batched capabilities succeeded.

The six failed samples recorded HTTP `000`, curl exit `52`, and zero response bytes. They are transport failures—not completed latency observations, authorization denials, or confirmed client timeouts. Wide serial failed after 135–146s, below its 180s per-request deadline; sparse capabilities failed after 64–73s, below its 600s deadline. The quick review does not establish whether the underlying cause was worker termination, memory pressure, a proxy, or another server failure. Do not calculate a speedup against these failed runs. Their traces were archived successfully.

**Application cache.** Organization partition full walks, batched `/can`, batch 1000.

| Fixture | Cold Redis | Warm Redis | Cold/warm ratio |
| --- | ---: | ---: | ---: |
| Wide organization | 1.061 [0.963–1.251] | 0.745 [0.713–0.770] | 1.4× |
| Dense account, 20,000 users | 3.210 [3.122–3.307] | 3.136 [2.847–3.764] | 1.0× |

Wide partitions improved by about 30% in median latency. Dense partitions improved only about 2%, with overlapping ranges; this run does not support a broad claim that warm caching substantially speeds every workload.

**GraphQL MSP scale.** Batched `/can`, batch 10000. Complete paginated walks; the harness reported 9,999 / 49,999 / 99,999 returned accounts for the nominal 10k / 50k / 100k fixtures. Use those actual returned counts alongside the fixture labels; do not silently round them into exact returned cardinalities.

| Nominal fixture (pages) | Redis off | Redis cold | Redis warm | Off/warm ratio |
| --- | ---: | ---: | ---: | ---: |
| 10k (1) | 16.693 [16.534–16.972] | 7.474 [7.165–7.826] | 2.135 [2.103–2.302] | 7.8× |
| 50k (5) | 84.470 [83.670–87.601] | 37.970 [37.413–38.872] | 11.603 [10.843–13.206] | 7.3× |
| 100k (10) | 175.411 [174.357–183.449] | 78.770 [78.492–81.241] | 24.058 [22.257–28.946] | 7.3× |

All these walks succeeded, with zero recorded loading probes. At 100k, the measured HTTP-time total fell from 175.4s without Redis to 78.8s cold and 24.1s warm. This is a multi-organization MSP result, not evidence for a single organization of that size.

**Batch boundaries.** Same nominal MSP 10k walk, Redis enabled, `/can`.

| Batch size | Pages | Cold | Warm |
| --- | ---: | ---: | ---: |
| 200 | 50 | 18.441 [18.074–22.060] | 10.264 [10.101–10.438] |
| 1000 | 10 | 9.892 [9.704–10.360] | 3.597 [3.465–3.664] |
| 10000 | 1 | 7.474 [7.165–7.826] | 2.135 [2.103–2.302] |

Batch 10000 versus 200 reduced the median warm full-walk total by 4.8× and cold by 2.5×. Larger batches won in this tested range; this does not establish an optimal batch size or a memory/throughput tradeoff. For ordinary dense GraphQL at batch 10000, warm median was 3.770s versus 3.279s cold—another reason to keep cache claims workload-specific.

**Trace coverage and the 17 GB output.** The file-size inventory found 11,383 files totaling 17.695 GB (16.48 GiB) of logical bytes. Trace payloads account for 16.419 GB, about 92.8%. The largest trace is approximately 241 MB. The 17 timing CSVs total only 430,704 bytes.

All 1,115 distinct trace IDs referenced by timing rows matched 1,115 archived trace-status sidecars, with no missing or extra IDs. Sidecars report 8,202,998 spans in total, including exported warm-up traces and failed-request traces. Hierarchy requests share a trace within a sample; hierarchy warm-up traces are not exported. “Archived” means the archiver observed settled, connected spans; it is not independent proof that instrumentation dropped no spans.

This review scanned file metadata first, read timing CSVs and small collection/status files, and used `jq` to aggregate only small trace-status sidecars. It did not parse any raw Jaeger trace payload or large response body. Therefore it makes no service-specific span-count, SQL-count, physical-round-trip, peak-memory, or root-cause claim.

For the article series, use the hierarchy and batching comparisons as evidence that reducing client/server round trips matters, distinguish successful `/can` comparisons from capabilities failures, and show caching gains by workload. Keep three-run results descriptive: medians and ranges, no p95/p99, saturation-throughput, or general scalability limits. Server-model and queue-product comparisons were not part of this matrix.

Compact extracted comparisons: [JSON data](summary/article-2026-09-10-data.json). Raw completion summary: [collection status](raw/article-no-x-20260910T011818Z/collection_status.json).
