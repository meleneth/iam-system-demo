-- The grant lookup used by Authorization::Capabilities#canonical_account_ids_with_permission.
-- Concrete inputs for wide-org admin 92687b83-c34a-5d06-8dcb-d659b6506bd0
-- checking the root, two children, and an unrelated MSP account.
-- Group membership and effective ancestry were resolved by the production service.
-- /can uses this lookup for cache misses, then maps returned scopes to targets in Ruby.
-- Expected: one row, the wide-org root scope. This is not a per-target decision table.
SELECT "capability_grants"."scope_id"
FROM "capability_grants"
WHERE "capability_grants"."group_id" IN (
  '64507a30-e060-589f-b379-1a0a41223b42',
  '94c618ec-19f1-524b-9a46-391d592ada38'
)
  AND "capability_grants"."scope_type" = 'Account'
  AND "capability_grants"."scope_id" IN (
    '0d7e5b06-6e9e-5ba6-9c52-2416887853a2',
    'c84c2029-d184-5fbe-8e02-687e0d64a36b',
    '24870b5e-9bf1-5579-9196-aac45fcd04bf',
    'b05e3a9d-ee13-5d71-b248-beaf964c893f'
  )
  AND "capability_grants"."permission" = 'account.users.read';
