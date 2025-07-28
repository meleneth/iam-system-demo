README still under construction, more detail coming!

This codebase is to simulate (and optimize) the authorization explosion when loading a user management interface in a large distributed system
centered around IAM.

Note that in a live system, service to service requests should not be trusted unless the requests are at least signed, which is omitted here.

All primary keys are UUID's.

Accounts have parent_account_id, which may by nil if this is the 'top level' account.  For extra fun, grants are inherited from your parent account.

Every account will have an Organization.  Organization-service has a OrganizationAccounts table that as an entry per Account saying which Organization it belongs to.  The first user created for an Organization will be the Admin user, which has additional grants.

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

## Redis cache: Organization Accounts
Not implemented yet, likely coming soon

## Redis cache: per-grant Authorization cache
Not implemented yet, next to be implemented

This is on the Authorization redis cache.  We will need 2 sets per authorization.  The first set is the per-account redis keys that include information about this account, so that at invalidation time those sets can be deleted.

The other is the per-user authorization cache, that is also per-capability.

Details are forthcoming, but this should let us check multiple accounts for permission in a single redis call.  In the normal case where you have the capability and the data is already cached, it's one redis call with multiple keys and will return true quickly so you can say 'authorized' and move on.

In the not cached case, we can send a SNS message to 'cache this user's capability matching "X"' then do the slow db check for the keys instead.

On account / user modifications that can change the cached capabilities, we can send an SQS message to clear out the information (we probably want to retrieve the keys from redis from 'the first set' and encode them in the SQS message, then delete 'the first set' ourself - needs more thinking, I think the normal service will never check the first set itself so that might not be good enough)

I think we can set the redis cache to delete the sets after 5 minutes, we can either just let the delete happen or update the invalidation time.  Needs research.


# Implementation notes, for me:
<http://thinktank.sectorfour:8500/accounts/21881390-6912-401b-b33d-0cd74b3d08be?as=d918855f-4a53-4866-a8af-058a40876170>

./bin/rails generate rspec:install

This will add the API controller.

./bin/rails g scaffold_controller Users

in user-service/app/controllers/users_controller.rb

    def user_params
      params.require(:user).permit(
        :account_id, :email, :username, :first_name, :last_name, :middle_name,
        :phone_number, :alt_phone, :slack_id, :avatar_url, :linkedin, :github,
        :twitter, :tshirt_size, :pronouns, :timezone, :account_id
      )
    end

in user-service/app/models/user.rb

    class User < ApplicationRecord
      validates :account_id, presence: true
    end

in compose/user-management-service.yml

    USER_SERVICE_API_BASE_URL: http://user-service:80
    ACCOUNT_SERVICE_API_BASE_URL: http://account-service:80
    ORGANIZATION_SERVICE_API_BASE_URL: http://organization-service:80

in user-management-service/app/models

    class User < ActiveResource::Base
      self.site = ENV.fetch("USER_SERVICE_API_BASE_URL") # e.g., http://user-service:3000/
      self.format = :json

      # Optional: if the resource uses UUIDs instead of integers
      self.primary_key = "id"

      # Optional: if user-service uses a different collection path
      self.collection_name = "users"

      # Optional: handle nested resources, errors, etc.
    end
