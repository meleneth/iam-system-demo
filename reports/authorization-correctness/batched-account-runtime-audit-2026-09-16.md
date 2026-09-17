# Batched account authorization: runtime audit

**Verdict: PASS for the batched `/can/Account/account.read` query pattern.** The cold, three-target request made one actor-membership lookup, two batched hierarchy calls (targets, then providers), two batched provider-context calls, and **one** grant SQL query constraining group, Account scope type, candidate scope IDs, and `account.read`. Its single returned grant scope maps only to the leaf target. The warm repeat made no authoritative calls. Evicting one denied target's decision key caused only that target to be recomputed; it remained denied.

**Endpoint distinction:** `POST /capabilities/Account` returns the requested per-target capability map correctly, but currently loops over accounts and runs three separate all-permission grant queries. It does **not** demonstrate the `/can` batching pattern. The earlier version of this report mislabeled that observation as the outcome of the `/can` audit. The two endpoints' different SQL shapes are reported separately below. If the requirement is that the capability-list endpoint itself perform one grant query, that separate requirement **fails**; its all-permission query has no requested-permission predicate by design.

## Stack and independently established fixture

Authorization source commit `45a97cba6f70bbcfb2d007a6af6b8145d26f4e88`; test stack `gt`, `RAILS_ENV=test`, `AUTHORIZATION_CHECK_MODE=can`, `GLOBAL_IAM_DEMO_USE_REDIS=true`, authorization Redis DB 1. The `a1710000` deterministic fixture was already persisted; no seed, schema, production code, or instrumentation was changed. Temporary test Compose services `accountcache` and `orgcache` were needed because the checked-in test Compose stack omits them. The source code was unchanged between the initial and corrected audit runs.

Actor: `a1710000-0000-4000-8000-8db307e4fdb1` (`actor_read_child`). Permission: `account.read`. Direct queries to the owning databases, before authorization requests, found exactly one explicit membership: row `a1710000-0000-4000-8000-2dfe648d0c30`, group `a1710000-0000-4000-8000-8970b7cd6d4a`. That group's owning account is foreign provider `a1710000-0000-4000-8000-042b229f0e88`; ownership grants nothing. The group's only grant is row `d44135fb-3bc2-4ce6-809e-5a6b7fdc08a4`: `account.read`, `Account`, scope **child** `a1710000-0000-4000-8000-ddc9e6691942`.

| Target | Physical parent chain from account DB, target first | Organization/provider relationship from organization DB | Expected |
| --- | --- | --- | --- |
| Leaf `a1710000-0000-4000-8000-9f91161f4343` | leaf → child `...ddc9e6691942` → root `...4813494d137e` | client org `...948fe603f61d` → provider `...5c4c1964340a`, provider org `...6f991db57ca2` | **Allow**: child is on this chain. |
| Sibling `a1710000-0000-4000-8000-7d10de8554ed` | sibling → root `...4813494d137e` | same client/provider edge | **Deny**: child is absent; provider affiliation adds no grant. |
| Foreign `a1710000-0000-4000-8000-656771905e1e` | foreign, no parent | other client org `...7b01719b8b98` → foreign provider `...042b229f0e88`, provider org `...044cabb85465` | **Deny**: child is absent from physical and virtual ancestry. |

The provider accounts are absent from all three persisted **physical** chains. Virtual provider ancestry is used only for authorization scope construction. Expected decisions above came from the persisted membership, grant, hierarchy, and relationship rows, never from the production resolver.

## Cold `/can` batch: correlated runtime proof

Request: `POST /can/Account/account.read`, real `pad-user-id` set to the actor UUID, JSON `{"scope_id":["a1710000-0000-4000-8000-9f91161f4343","a1710000-0000-4000-8000-7d10de8554ed","a1710000-0000-4000-8000-656771905e1e"]}`. Response: **403** `{"error":"Forbidden"}`, because `/can` requires all targets to pass. Request ledger [can-cold-request.json](batched-account-evidence/can-cold-request.json) records trace ID `a6e56b7011f041cfaa757ae851047f49` and its initiating span ID. The [40-span Jaeger trace](batched-account-evidence/can-cold-trace.json) contains exactly one authorization server span referencing that initiating span. The [ordered extract](batched-account-evidence/can-cold-authorization-operations.json) lists every authorization-service operation.

| Authorization-service operation | Count | Observed behavior |
| --- | ---: | --- |
| Redis pipeline | 2 | First **3 GET** decision keys; last **3 SET** (`true`, `false`, `false`, `EX 300`). |
| HTTP `POST /accounts_with_parents` | 2 | First batched call resolves the three requested physical chains (server span “Load 6 accounts”); second resolves the distinct provider frontiers (server span “Load 3 accounts”). |
| HTTP `POST /internal/auth/account_providers` | 2 | First batched call finds three relationships; second finds zero further provider edges. |
| HTTP `POST /internal/auth/memberships` | **1** | Finds one explicit actor membership. This narrow lookup uses `IAM_SYSTEM_AUTH`; the initiating `/can` request uses the actor UUID, and the hierarchy fact lookup uses `IAM_SYSTEM` only as an internal context fetch. The observed `/can` request did not bypass membership or grant evaluation. |
| Authorization-service SQL | **1** | One `CapabilityGrant Pluck`; zero reads of `legacy_user_capability_grants`. |

The traced SQL, with bind values already inlined, is preserved in [can-cold-authorization-sql.sql](batched-account-evidence/can-cold-authorization-sql.sql):

```sql
SELECT "capability_grants"."scope_id"
FROM "capability_grants"
WHERE "capability_grants"."group_id" = 'a1710000-0000-4000-8000-8970b7cd6d4a'
  AND "capability_grants"."scope_type" = 'Account'
  AND "capability_grants"."scope_id" IN (
    'a1710000-0000-4000-8000-4813494d137e',
    'a1710000-0000-4000-8000-ddc9e6691942',
    'a1710000-0000-4000-8000-9f91161f4343',
    'a1710000-0000-4000-8000-2d2adb393946',
    'a1710000-0000-4000-8000-5c4c1964340a',
    'a1710000-0000-4000-8000-7d10de8554ed',
    'a1710000-0000-4000-8000-656771905e1e',
    'a1710000-0000-4000-8000-042b229f0e88'
  )
  AND "capability_grants"."permission" = 'account.read'
  /*action='index',application='AuthorizationService',controller='can'*/;
```

The same predicate queried directly against the owning authz database returns only [child `...ddc9e6691942`](batched-account-evidence/can-grant-result.txt). The leaf's authorization scopes contain child. The sibling's scopes contain root, sibling, provider root, and provider, but no child. The foreign target's scopes contain foreign and foreign provider, but no child. The returned scope set is checked separately against each target's scope list. Redis MONITOR independently records the resulting target-specific `true`, `false`, `false` writes in [can-redis-monitor.txt](batched-account-evidence/can-redis-monitor.txt). One allowed target did not authorize its siblings or unrelated accounts.

The Jaeger HTTP spans record dependency path, status, and returned item counts, but not request or response bodies. Thus the exact downstream HTTP payload arrays are established by the controller/client implementation and the recorded item counts, rather than captured payload text; the complete initiating request body is in the ledger. The SQL statement and Redis commands are directly captured runtime data. Account hierarchy service cache entries were already warm during this authorization-cache cold request, so the trace proves batched **calls** for hierarchy resolution rather than a cold account-service hierarchy SQL execution.

## Warm and one-target partial cache

The identical warm `/can` request returned the identical **403**. [Trace `2ad0880c45c24797900552169ba6dcb0`](batched-account-evidence/can-warm-trace.json) contains only the server span, account permission span, and **one Redis pipeline of 3 GETs**. Membership, hierarchy, provider-context calls, and grant SQL are absent. The three keys are `group-grants-v2:can:<actor>:Account:account.read:<target>`, one for each listed UUID. The [warm ledger](batched-account-evidence/can-warm-request.json) and [operation extract](batched-account-evidence/can-warm-authorization-operations.json) identify the request.

I then deleted **only the sibling's** `/can` decision key and repeated the mixed request. It again returned **403**. [Trace `b7e5891467b647a8a5c2eec2df9acccd`](batched-account-evidence/can-partial-trace.json) shows a 3-GET pipeline, one hierarchy call for sibling, one for its provider frontier, two provider-context calls, one membership lookup, **one** grant query whose scope IDs are restricted to sibling's own ancestry, and **one** Redis SET of sibling `false`. The leaf and foreign keys were read but not rewritten. See the [partial request](batched-account-evidence/can-partial-request.json), [operation extract](batched-account-evidence/can-partial-authorization-operations.json), [SQL](batched-account-evidence/can-partial-authorization-sql.sql), and [Redis ledger](batched-account-evidence/can-redis-monitor.txt). The partial SQL contains no child scope, so the cached leaf's authority could not be borrowed.

## Capability map and individual controls

The separate cold and warm `POST /capabilities/Account` requests both returned HTTP 200 with the independent map `{leaf:["account.read"], sibling:[], foreign:[]}`. Their [cold](batched-account-evidence/final-cold-trace.json) and [warm](batched-account-evidence/final-warm-trace.json) traces show that this endpoint loops over each target: three independent all-permission grant queries cold, then three capability-list cache GETs warm. Those queries correctly fetch capability names and therefore do not filter on one requested permission. This endpoint's batching performance does **not** meet the one-query criterion; it is not the `/can` batch algorithm.

Individual `POST /can/Account/account.read` controls returned **200** for leaf and **403** for sibling and foreign. The mixed control returned **403**. [Control response ledger](batched-account-evidence/can-controls.json). Cold, warm, partial-cache, individual, capability-list, and mixed results agree on each target's authority.

## Reproduction commands

Run from the repository root against the **test** stack and the already persisted `a1710000` fixture. Do not seed or reset databases for this audit.

```bash
./dc_test up -d account-db authz-db group-db organization-db authorization-service account-auth-service organization-auth-service group-auth-service organization-service authcache otel-collector jaeger
cat > /tmp/iam-audit-cache-services.yml <<'YAML'
services:
  accountcache: { image: redis:8.10.1-trixie }
  orgcache: { image: redis:8.10.1-trixie }
YAML
./dc_test -f /tmp/iam-audit-cache-services.yml up -d accountcache orgcache
actor=a1710000-0000-4000-8000-8db307e4fdb1
leaf=a1710000-0000-4000-8000-9f91161f4343
sibling=a1710000-0000-4000-8000-7d10de8554ed
foreign=a1710000-0000-4000-8000-656771905e1e
./dc_test exec -T group-db psql -U group-db-test-user -d group-db_test -c "select gu.id,gu.user_id,gu.group_id,g.account_id from group_users gu join groups g on g.id=gu.group_id where gu.user_id='$actor';"
./dc_test exec -T authz-db psql -U authz-db-test-user -d authz-db_test -c "select id,group_id,permission,scope_type,scope_id from capability_grants where group_id='a1710000-0000-4000-8000-8970b7cd6d4a';"
./dc_test exec -T account-db psql -U account-db-test-user -d account-db_test -c "with recursive h as (select id,parent_account_id,id target,0 depth from accounts where id in ('$leaf','$sibling','$foreign') union all select a.id,a.parent_account_id,h.target,h.depth+1 from accounts a join h on a.id=h.parent_account_id where h.depth<20) select * from h order by target,depth;"
./dc_test exec -T organization-db psql -U organization-db-test-user -d organization-db_test -c "select oa.account_id,oa.organization_id,m.msp_account_id,m.msp_organization_id,m.client_organization_id from organization_accounts oa left join msp_managed_organizations m on m.client_organization_id=oa.organization_id where oa.account_id in ('$leaf','$sibling','$foreign');"
./dc_test exec -T authcache redis-cli -n 1 DEL "group-grants-v2:capabilities:$actor:Account:$leaf" "group-grants-v2:capabilities:$actor:Account:$sibling" "group-grants-v2:capabilities:$actor:Account:$foreign" "group-grants-v2:can:$actor:Account:account.read:$leaf" "group-grants-v2:can:$actor:Account:account.read:$sibling" "group-grants-v2:can:$actor:Account:account.read:$foreign"
body=$(printf '{"scope_id":["%s","%s","%s"]}' "$leaf" "$sibling" "$foreign")
trace_id=$(python3 -c 'import uuid; print(uuid.uuid4().hex)')
parent_id=$(python3 -c 'import uuid; print(uuid.uuid4().hex[:16])')
curl -sS -i -X POST http://localhost:11110/can/Account/account.read -H "pad-user-id: $actor" -H 'Content-Type: application/json' -H "traceparent: 00-$trace_id-$parent_id-01" --data "$body"
curl -sS "http://localhost:11030/api/traces/$trace_id"
curl -sS -i -X POST http://localhost:11110/can/Account/account.read -H "pad-user-id: $actor" -H 'Content-Type: application/json' --data "$body"
./dc_test exec -T authcache redis-cli -n 1 DEL "group-grants-v2:can:$actor:Account:account.read:$sibling"
curl -sS -i -X POST http://localhost:11110/can/Account/account.read -H "pad-user-id: $actor" -H 'Content-Type: application/json' --data "$body"
for target in "$leaf" "$sibling" "$foreign"; do curl -sS -o /dev/null -w '%{http_code}\n' -X POST http://localhost:11110/can/Account/account.read -H "pad-user-id: $actor" -H 'Content-Type: application/json' --data "{\"scope_id\":[\"$target\"]}"; done
```

For a Redis command ledger, run `./dc_test exec -T authcache redis-cli MONITOR` in a second terminal before the three traced requests and filter by actor UUID. Jaeger export is asynchronous; retry its trace URL until the spans appear. The archived traces and request ledgers above are the stable identifiers for this run.
