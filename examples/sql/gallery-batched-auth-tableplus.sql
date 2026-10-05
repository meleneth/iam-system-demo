-- Wide-org admin 92687b83-c34a-5d06-8dcb-d659b6506bd0.
-- Membership/ancestry context verified through prod auth service 2026-10-05.
-- Read live grants in authz-db_production; context is a snapshot from other services.
WITH targets(label, account_id, ancestor_id) AS (
  VALUES
    ('root', '0d7e5b06-6e9e-5ba6-9c52-2416887853a2'::uuid, NULL::uuid),
    ('child 1', 'c84c2029-d184-5fbe-8e02-687e0d64a36b'::uuid, '0d7e5b06-6e9e-5ba6-9c52-2416887853a2'::uuid),
    ('child 2', '24870b5e-9bf1-5579-9196-aac45fcd04bf'::uuid, '0d7e5b06-6e9e-5ba6-9c52-2416887853a2'::uuid),
    ('unrelated account', 'b05e3a9d-ee13-5d71-b248-beaf964c893f'::uuid, NULL::uuid)
)
SELECT t.label, t.account_id, 'account.users.read' AS permission,
       count(g.id) > 0 AS allowed,
       array_agg(DISTINCT g.scope_id) FILTER (WHERE g.id IS NOT NULL) AS matching_grant_scopes
FROM targets t
LEFT JOIN public.capability_grants g
  ON g.group_id IN ('64507a30-e060-589f-b379-1a0a41223b42'::uuid, '94c618ec-19f1-524b-9a46-391d592ada38'::uuid)
 AND g.scope_type = 'Account'
 AND g.permission = 'account.users.read'
 AND g.scope_id IN (t.account_id, t.ancestor_id)
GROUP BY t.label, t.account_id
ORDER BY t.label;
