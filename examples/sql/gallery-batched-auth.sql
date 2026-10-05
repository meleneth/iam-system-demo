-- Run this entire SELECT in TablePlus against authz-db_production (127.0.0.1:11330).
-- Read-only batch: eight account/permission decisions, including two denials.
-- Memberships and effective account scopes were resolved through the production
-- authorization service on 2026-10-05. Those facts live in other service DBs;
-- the VALUES below are a context snapshot, not an auth-db membership lookup.
-- Effective scopes include the target, physical ancestors, and MSP provider
-- ancestry via the client organization. They do not change parent_account_id.
-- Grants are read LIVE from public.capability_grants, and belong only to groups.
-- Refresh the context if memberships, parentage, or MSP relationships change.
-- Expected: six allowed, two denied, all matches_service_snapshot = true.
-- /can on a batch returns 200 only if EVERY requested decision is allowed.
WITH actors(actor, user_id, group_ids) AS (
  VALUES
    ('wide-admin', '92687b83-c34a-5d06-8dcb-d659b6506bd0'::uuid, ARRAY['64507a30-e060-589f-b379-1a0a41223b42', '94c618ec-19f1-524b-9a46-391d592ada38']::uuid[]),
    ('msp-admin', 'f3a85e16-4fea-53c0-b31a-8ac822431f9a'::uuid, ARRAY['62534448-5660-5ebb-8538-007c47377fb9', '7581884c-4add-5e95-8d3a-f91b6d3d30d3']::uuid[])
), questions(actor, account_id, permission, effective_scope_ids, service_allowed) AS (
  VALUES
    ('wide-admin', '0d7e5b06-6e9e-5ba6-9c52-2416887853a2'::uuid, 'account.users.read', ARRAY['0d7e5b06-6e9e-5ba6-9c52-2416887853a2']::uuid[], true),
    ('wide-admin', 'c84c2029-d184-5fbe-8e02-687e0d64a36b'::uuid, 'account.users.read', ARRAY['0d7e5b06-6e9e-5ba6-9c52-2416887853a2', 'c84c2029-d184-5fbe-8e02-687e0d64a36b']::uuid[], true),
    ('wide-admin', '24870b5e-9bf1-5579-9196-aac45fcd04bf'::uuid, 'account.users.read', ARRAY['0d7e5b06-6e9e-5ba6-9c52-2416887853a2', '24870b5e-9bf1-5579-9196-aac45fcd04bf']::uuid[], true),
    ('wide-admin', 'b05e3a9d-ee13-5d71-b248-beaf964c893f'::uuid, 'account.users.read', ARRAY['b05e3a9d-ee13-5d71-b248-beaf964c893f']::uuid[], false),
    ('msp-admin', 'b05e3a9d-ee13-5d71-b248-beaf964c893f'::uuid, 'account.users.read', ARRAY['b05e3a9d-ee13-5d71-b248-beaf964c893f']::uuid[], true),
    ('msp-admin', '58a81259-a9e6-5a79-b80e-20d4a14e716d'::uuid, 'account.users.read', ARRAY['58a81259-a9e6-5a79-b80e-20d4a14e716d', 'b05e3a9d-ee13-5d71-b248-beaf964c893f']::uuid[], true),
    ('msp-admin', '624051c4-0021-5406-89eb-86ecf4d666e3'::uuid, 'account.users.read', ARRAY['624051c4-0021-5406-89eb-86ecf4d666e3', 'b05e3a9d-ee13-5d71-b248-beaf964c893f']::uuid[], true),
    ('wide-admin', '0d7e5b06-6e9e-5ba6-9c52-2416887853a2'::uuid, 'account.delete', ARRAY['0d7e5b06-6e9e-5ba6-9c52-2416887853a2']::uuid[], false)
), decisions AS (
  SELECT a.actor, a.user_id, q.account_id, q.permission,
         q.effective_scope_ids, q.service_allowed,
         count(g.id) > 0 AS allowed,
         array_agg(DISTINCT g.group_id) FILTER (WHERE g.id IS NOT NULL) AS matching_group_ids,
         array_agg(DISTINCT g.scope_id) FILTER (WHERE g.id IS NOT NULL) AS matching_grant_scope_ids,
         array_agg(DISTINCT g.id) FILTER (WHERE g.id IS NOT NULL) AS matching_grant_ids
  FROM questions q
  JOIN actors a USING (actor)
  LEFT JOIN public.capability_grants g
    ON g.group_id = ANY(a.group_ids)
   AND g.scope_type = 'Account'
   AND g.scope_id = ANY(q.effective_scope_ids)
   AND g.permission = q.permission
  GROUP BY a.actor, a.user_id, q.account_id, q.permission,
           q.effective_scope_ids, q.service_allowed
)
SELECT actor, user_id, account_id, permission, allowed,
       allowed = service_allowed AS matches_service_snapshot,
       matching_group_ids, matching_grant_scope_ids, matching_grant_ids,
       effective_scope_ids
FROM decisions
ORDER BY actor, account_id, permission;
