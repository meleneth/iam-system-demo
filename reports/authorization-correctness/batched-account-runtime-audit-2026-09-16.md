# Batched account authorization runtime audit

**Verdict: FAIL.** `POST /capabilities/Account` returned the correct independent answers, but its cold three-target request issued **three** grant queries and resolved hierarchy and provider context separately for each target. Each grant query omitted `permission`; it selected all capability names for one target. The requested single group/scope/permission intersection query did not run on this endpoint. This is a query-pattern failure, not an observed authorization leak. The audit stopped after the decisive cold trace, warm repeat, and `/can` controls; no code, fixture, schema, or seed data was changed.

## Environment and independently checked facts

- Source commit: `45a97cba6f70bbcfb2d007a6af6b8145d26f4e88` (`main`). Test stack `gt`, `RAILS_ENV=test`, `AUTHORIZATION_CHECK_MODE=can`, `GLOBAL_IAM_DEMO_USE_REDIS=true`; authorization Redis DB 1. Persisted `RecordAuthorizationFixture` rows were present in all four owning databases before the request. `accountcache` and `orgcache` were supplied as temporary test Compose services because the checked-in test Compose file lacks them; no database was reseeded. The temporary override was `/tmp/iam-audit-cache-services.yml`.
- Actor `a1710000-0000-4000-8000-8db307e4fdb1` (`actor_read_child`), permission `account.read`.
- Group DB: the actor has exactly one explicit membership, row `a1710000-0000-4000-8000-2dfe648d0c30`, in group `a1710000-0000-4000-8000-8970b7cd6d4a`. The group's owning account is `a1710000-0000-4000-8000-042b229f0e88` (`foreign_provider`); ownership itself supplies no grant.
- Authorization DB: that group's only grant is row `d44135fb-3bc2-4ce6-809e-5a6b7fdc08a4`: `account.read`, `Account`, scope `a1710000-0000-4000-8000-ddc9e6691942` (`child`). These facts came from direct SQL on group DB and authz DB, not from the resolver.

| Target | Physical chain, target to root, from account DB | Organization/provider facts from organization DB | Hand-derived `account.read` |
| --- | --- | --- | --- |
| Leaf `a1710000-0000-4000-8000-9f91161f4343` | leaf → child `...ddc9e6691942` → root `...4813494d137e` | client org `...948fe603f61d` links to provider `...5c4c1964340a` in provider org `...6f991db57ca2` | **Allow**: child is on its physical chain. |
| Sibling `a1710000-0000-4000-8000-7d10de8554ed` | sibling → root `...4813494d137e` | same client/provider relationship | **Deny**: child is absent from its chain. Provider relationship alone confers no grant. |
| Foreign `a1710000-0000-4000-8000-656771905e1e` | foreign, no parent | other client org `...7b01719b8b98` links to foreign provider `...042b229f0e88` in org `...044cabb85465` | **Deny**: child is absent from its physical and virtual ancestry. |

The provider accounts are absent from all three persisted physical parent chains. They are separate virtual context facts.

## Correlated cold request

`POST /capabilities/Account`, `pad-user-id: a1710000-0000-4000-8000-8db307e4fdb1`, body `{"scope_id":["a1710000-0000-4000-8000-9f91161f4343","a1710000-0000-4000-8000-7d10de8554ed","a1710000-0000-4000-8000-656771905e1e"]}`. HTTP 200; response map: leaf `['account.read']`, sibling `[]`, foreign `[]`. The request record has trace ID `feb6840e3a684711817c26d19b67d1e7` and initiating parent span ID; the Jaeger trace has one server span directly referencing that parent and contains 46 spans, including 20 authorization-service spans. This ties the inventory to this exact request.

| Authorization-service operation | Cold count | Observed detail |
| --- | ---: | --- |
| HTTP `POST /accounts_with_parents` | **6** | Two calls per target: target physical chain and its provider account chain. Each call carries one target ID, although the endpoint supports arrays. |
| HTTP `POST /internal/auth/account_providers` | **6** | Two calls per target: first returns one provider edge; second returns none. Each lookup carries one account ID. |
| HTTP `POST /internal/auth/memberships` | **1** | Returns one membership. `IAM_SYSTEM_AUTH` is used only for this context lookup; the initiating request carries the real actor UUID. |
| Authorization-service SQL | **3** | Three `CapabilityGrant Pluck` statements below. No other authorization-service SQL span. No `legacy_user_capability_grants` read. |
| Authorization Redis, DB 1 | **3 GET, 3 SET** | One capability-list key per target, each SET with `EX 300`; values are `["account.read"]`, `[]`, `[]`. The synchronized Redis MONITOR also records the preparatory three-key DEL, which is outside the HTTP request. No `/can` decision key was accessed. |

The HTTP spans record paths, status 200, and returned item counts, but do not record dependency request/response bodies. The request body is preserved in the request ledger. Persisted facts above establish the relevant dependency content independently. See the [cold trace](batched-account-evidence/final-cold-trace.json), [ordered authorization operation extract](batched-account-evidence/final-cold-authorization-operations.json), [request ledger](batched-account-evidence/final-cold-request.json), and [Redis monitor](batched-account-evidence/redis-monitor-valid.txt).

The actual three SQL statements, with values inlined by the tracing instrumentation, are in [cold SQL extract](batched-account-evidence/final-cold-authorization-sql.sql). The first is:

```sql
SELECT DISTINCT "capability_grants"."permission" FROM "capability_grants"
WHERE "capability_grants"."group_id" = 'a1710000-0000-4000-8000-8970b7cd6d4a'
  AND "capability_grants"."scope_type" = 'Account'
  AND "capability_grants"."scope_id" IN (
    'a1710000-0000-4000-8000-4813494d137e',
    'a1710000-0000-4000-8000-ddc9e6691942',
    'a1710000-0000-4000-8000-9f91161f4343',
    'a1710000-0000-4000-8000-2d2adb393946',
    'a1710000-0000-4000-8000-5c4c1964340a'
  ) /*action='accounts',application='AuthorizationService',controller='capabilities'*/;
```

The second query uses scope IDs root, sibling, provider root, provider. The third uses foreign, foreign provider. Thus the child grant occurs only in the leaf query's scopes, and each target's response is reconstructed separately by its own query. These statements constrain `group_id`, `scope_type`, and `scope_id`, but **none constrains `permission`**. The three queries are not necessary for the shared `/can` batch algorithm: `Capabilities#account_ids_with_permission` has a separate one-query implementation. The observed endpoint calls `for_account` once per ID through `CapabilitiesController#accounts` and `capability_map`.

## Warm repeat and controls

The identical warm `POST /capabilities/Account` returned the identical 200 map. Trace `29add9c96f2d4570a9cf894f73689ec3` has four spans: one authorization-service server span and three per-account internal spans. It has **zero dependency HTTP calls and zero SQL statements**. Synchronized Redis MONITOR records **three GETs**, one for each `group-grants-v2:capabilities:<actor>:Account:<target>` key, and no SET. These are capability-list keys, not `group-grants-v2:can:<actor>:Account:account.read:<target>` decision keys. See [warm trace](batched-account-evidence/final-warm-trace.json), [warm operation extract](batched-account-evidence/final-warm-authorization-operations.json), and [warm request](batched-account-evidence/final-warm-request.json).

`POST /can/Account/account.read` with the same actor returned 200 for leaf individually, 403 for sibling individually, 403 for foreign individually, and 403 for the mixed three-target batch, as required by `/can` all-target semantics. See [control responses](batched-account-evidence/can-controls.json). No provider-only or cross-target allow was observed. A partial-cache run was not performed: the cold trace already met two explicit audit failure conditions, so the experiment stopped without further cache manipulation.

## Reproduction

Run from the repository root on the **test** stack only. The existing `a1710000` persisted fixture must already be present; do not run a seed script for this audit.

```bash
git rev-parse HEAD
./dc_test up -d account-db authz-db group-db organization-db authorization-service account-auth-service organization-auth-service group-auth-service organization-service authcache otel-collector jaeger
cat > /tmp/iam-audit-cache-services.yml <<'YAML'
services:
  accountcache: { image: redis:8.10.1-trixie }
  orgcache: { image: redis:8.10.1-trixie }
YAML
./dc_test -f /tmp/iam-audit-cache-services.yml up -d accountcache orgcache
./dc_test exec -T group-db psql -U group-db-test-user -d group-db_test -c "select gu.id,gu.user_id,gu.group_id,g.account_id from group_users gu join groups g on g.id=gu.group_id where gu.user_id='a1710000-0000-4000-8000-8db307e4fdb1';"
./dc_test exec -T authz-db psql -U authz-db-test-user -d authz-db_test -c "select id,group_id,permission,scope_type,scope_id from capability_grants where group_id='a1710000-0000-4000-8000-8970b7cd6d4a';"
./dc_test exec -T account-db psql -U account-db-test-user -d account-db_test -c "with recursive h as (select id,parent_account_id,id target,0 depth from accounts where id in ('a1710000-0000-4000-8000-9f91161f4343','a1710000-0000-4000-8000-7d10de8554ed','a1710000-0000-4000-8000-656771905e1e') union all select a.id,a.parent_account_id,h.target,h.depth+1 from accounts a join h on a.id=h.parent_account_id where h.depth<20) select * from h order by target,depth;"
./dc_test exec -T organization-db psql -U organization-db-test-user -d organization-db_test -c "select oa.account_id,oa.organization_id,m.msp_account_id,m.msp_organization_id,m.client_organization_id from organization_accounts oa left join msp_managed_organizations m on m.client_organization_id=oa.organization_id where oa.account_id in ('a1710000-0000-4000-8000-9f91161f4343','a1710000-0000-4000-8000-7d10de8554ed','a1710000-0000-4000-8000-656771905e1e');"
actor=a1710000-0000-4000-8000-8db307e4fdb1
leaf=a1710000-0000-4000-8000-9f91161f4343
sibling=a1710000-0000-4000-8000-7d10de8554ed
foreign=a1710000-0000-4000-8000-656771905e1e
./dc_test exec -T authcache redis-cli -n 1 DEL "group-grants-v2:capabilities:$actor:Account:$leaf" "group-grants-v2:capabilities:$actor:Account:$sibling" "group-grants-v2:capabilities:$actor:Account:$foreign" "group-grants-v2:can:$actor:Account:account.read:$leaf" "group-grants-v2:can:$actor:Account:account.read:$sibling" "group-grants-v2:can:$actor:Account:account.read:$foreign"
trace_id=$(python3 -c 'import uuid; print(uuid.uuid4().hex)')
parent_id=$(python3 -c 'import uuid; print(uuid.uuid4().hex[:16])')
body=$(printf '{"scope_id":["%s","%s","%s"]}' "$leaf" "$sibling" "$foreign")
curl -sS -X POST http://localhost:11110/capabilities/Account -H "pad-user-id: $actor" -H 'Content-Type: application/json' -H "traceparent: 00-$trace_id-$parent_id-01" --data "$body"
curl -sS "http://localhost:11030/api/traces/$trace_id"
curl -sS -X POST http://localhost:11110/capabilities/Account -H "pad-user-id: $actor" -H 'Content-Type: application/json' --data "$body"
for target in "$leaf" "$sibling" "$foreign"; do curl -sS -o /dev/null -w '%{http_code}\n' -X POST http://localhost:11110/can/Account/account.read -H "pad-user-id: $actor" -H 'Content-Type: application/json' --data "{\"scope_id\":[\"$target\"]}"; done
curl -sS -o /dev/null -w '%{http_code}\n' -X POST http://localhost:11110/can/Account/account.read -H "pad-user-id: $actor" -H 'Content-Type: application/json' --data "$body"
```

For a synchronized Redis command ledger, run `./dc_test exec -T authcache redis-cli MONITOR` in another terminal immediately before the traced request; filter on the actor UUID. The stored trace IDs and Redis ledger above identify the exact measured run.
