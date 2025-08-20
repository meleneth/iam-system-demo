README still under construction, more detail coming!

PLEASE NOTE:
Many bits of this codebase are NOT PRODUCTION READY.
It exists to explore some SPECIFIC ideas around dataloader and multi-object fetching, and SHOULD NOT be used as an example of good coding standards.

Key deficiencies: Lack of unit tests, duplicate models amongst services, all credentials in the repository, race conditions in headers, and a complete lack of authentication.  There has also been a bit of drift from the generated service layout, and care was NOT taken to make sure that everything still works in all environments.

This codebase is to simulate (and optimize) the authorization explosion when loading a user management interface in a large distributed system
centered around IAM.

Note that in a live system, service to service requests should not be trusted unless the requests are at least signed, which is omitted here.

All primary keys are UUID's.

Accounts have parent_account_id, which may by nil if this is the 'top level' account.  For extra fun, grants are inherited from your parent account.

Every account will belong to an Organization.  Organization-service has a OrganizationAccounts table that as an entry per Account saying which Organization it belongs to.  The first user created for an Organization will be the Admin user, which has additional grants.

./dc_test, ./dc_dev, and ./dc_prod are docker compose helpers

    ./dc_test build

    ./dc_test up -d

makes 1 million users, 3 hours on my box

    ./dc_test run user-management-service bin/rails runner scripts/demo_user_seeder.rb

    ./dc_test run account-service bin/rails runner scripts/account_cte_query.rb

User seeder SQS message format:

    {
      type: "demo.user.create",
      index: integer, # unused
      user: {
        id: uuid,
        email: string,
        account_id: uuid
        is_admin: boolean
      },
      account: {
        id: uuid,
        parent_account_id: uuid # optional
      },
      organization: {
        id: uuid
      },
      groups: {
        id: uuid,
        name: string
      }
    }

is_admin_user is not stored directly in the database, but is reflected in the grants applied to the user.

Service / Database layout:

numbers after service names are the ports for test, dev, and production respectively

user-management-service: 11090, 11230,

the UI that users have access to.

/accounts/#{account_id}?as=IAM_SYSTEM will show 'the information' for that account with no auth checks.  if as has a user_id, that user's permission will be checked.

organization-service: , 11250

Organization id, name

OrganizationAccount id, organization_id, account_id

account-service: 11100, 11230, 

Account: id, name, parent_account_id

scripts/account_cte_query.rb

user-service: 11090, 11220,

User: id, email, account_id, a lot of other fields (all nil)

authorization-service: 11110, 11240

jaeger: 11030, 11160

this shows the spans that the system generates via OpenTelemetry as things happen

# Solution Space

## Multiple Record Retrieval
Getting one record back from an owning service at a time is a non starter.  We have implemented find such that you can provide multiple primary keys, and get all the records back in a single request.

## CTE query for parent_account_id
Databases are a bit awkward with hierarchical data.  That said, you can still get a flat result set back by using Common Table Expressions.  We do not want to retrieve a single account, check the parent account id, retrieve that account and keep going until we run out of parent_account_id, so we make the Account database do that work for us.

      WITH RECURSIVE account_hierarchy(id, level, name, name_path) AS (
        SELECT "accounts"."id", 0 AS level, "accounts"."name", ARRAY[name] AS name_path FROM "accounts" WHERE "accounts"."parent_account_id" IS NULL
        UNION ALL
        SELECT a.id, t0.level + 1, a.name, ARRAY_APPEND(t0.name_path, a.name)
      FROM accounts a
      INNER JOIN account_hierarchy t0 ON t0.id = a.parent_account_id

      )
      SELECT id, level, name_path[1] AS category, ARRAY_TO_STRING(name_path, ' > ')
      FROM account_hierarchy

This will return rows like

    [9] {
                     "id" => "abb37097-be57-4da9-ac08-249b327dfcac",
                  "level" => 13,
               "category" => "Account 32e03360-72b2-4cce-b738-8...",
        "array_to_string" => "Account 32e03360-72b2-4cce-b738-8... > Account 1f36dd41-8098-47c6-b34a-4... > Account 30282b04-9b21-4b98-a54f-3... > Account b4e5baca-7bd3-4a61-8be7-2... > Account b05aa9d3-a3ca-49b6-ae2f-f... > Account 8ee619db-c63f-4f12-a9c9-a... > Account dceec2e3-878f-4829-8cce-3... > Account 8e0cd0dd-02af-4ce6-95c2-5... > Account 46baf824-b544-416b-8ef0-7... > Account fb4335d7-9059-40c5-8afa-4... > Account 28dc5338-c101-4790-971c-2... > Account 27f18c73-72f3-4062-ad47-b... > Account 3889d031-dd36-4ad9-a713-7... > Account abb37097-be57-4da9-ac08-2..."
    }

As we can see, this an account 13 levels deep in an account hierarchy.  This query in particular unravels the account hierarchy for the entire table, but we can also unravel just one organization's worth at a time if we supply all the account id's.  Organization / Account mapping is stored remotely, so we can't just use the database to find that membership.

## REST API: Organization Acount ID's
organization-service has an api for returning account_ids for an organization.
Because we don't know the organization usually, but we always know our account_id because we know our user,
this API accepts an account_id and will internally look up the organization.

    organization_account_ids/for_account_id/:account_id

This will return 

    {
      organization: {
        {id: "1b486568-4214-49e5-bafb-5a381d4cdf1d", name: "Some Amazing Organization"}
      },
      account_ids: [
        "e006c8ed-eb76-4d54-8d41-81b84d882092",
        "ed4399a9-c0e6-4c24-b3f6-442dfae35fc9"
      ]
    }

This is a huge win because the naive approach requires a request to find the organization_id from this account id, and then another request to load the organization (to get the name), and then a THIRD request to get the account_id's that belong to the organization.  This is the root of all evil for latency.

## Cache Design
All caches expire in 5 minutes.  Keep-alive is not implemented, invalidation is not implemented.
Thought has been given to being able to invalidate, and extra keys are populated so that things could be invalidated - i.e. and organization level key will be populated with all the keys that are in that organization, such that all those keys could be deleted if the organization becomes modified.

## Redis cache: Organization Accounts
This is implemented.  This will return all of the account_id's that are in an organization.
Since this is organization keyed, this is trivial to delete when an Organization has changes to it's account structure. (Not implemented, since we never actually change these)

## Redis cache: Account Cache
This is implemented.  Getting an account with parents is constantly called for auth requests, so the redis cache keeps track of all parent accounts for each given account.  There is a secondary key that tracks all the keys for the organization that are loaded, for invalidation purposes (invalidation is not implemented)

## Redis cache: per-grant Authorization cache
This is on the Authorization redis cache.  We will need 2 sets per authorization.  The first set is the per-account redis keys that include information about this account, so that at invalidation time those sets can be deleted.

The other is the per-user authorization cache, that is also per-capability.

Details are forthcoming, but this should let us check multiple accounts for permission in a single redis call.  In the normal case where you have the capability and the data is already cached, it's one redis call with multiple keys and will return true quickly so you can say 'authorized' and move on.

In the not cached case, we can send a SNS message to 'cache this user's capability matching "X"' then do the slow db check for the keys instead.

On account / user modifications that can change the cached capabilities, we can send an SQS message to clear out the information (we probably want to retrieve the keys from redis from 'the first set' and encode them in the SQS message, then delete 'the first set' ourself - needs more thinking, I think the normal service will never check the first set itself so that might not be good enough)

I think we can set the redis cache to delete the sets after 5 minutes, we can either just let the delete happen or update the invalidation time.  Needs research.

## ActiveResource filtering:
By default out of the box, between Rails and ActiveResource filtering is 'not great'.  The controller returns the entire table, and filtering is done locally service side.

Not great.  I added a Mel::Filterable mixin, marked the filterable fields in the models, and modified the controller to use that functionality to require filters to be passed.  This unlocked the ability to request multiple records per request via passing arrays of id's, and between that and being able to filter on secondary keys was 'key' to getting this whole thing working.
