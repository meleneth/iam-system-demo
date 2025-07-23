README still under construction, more detail coming!

This codebase is to simulate the authorization explosion when loading a user management interface in a large distributed system
centered around IAM.

All primary keys are UUID's.

Accounts have parent_account_id, which may by nil if this is the 'top level' account.

Every account will have an Organization.

./dc_test, ./dc_dev, and ./dc_prod are docker compose helpers

    ./dc_test build

    ./dc_test up -d

makes 1 million users, 3 hours on my box

    ./dc_test run user-management-service bin/rails runner scripts/demo_user_seeder.rb

    ./dc_test run account-service bin/rails runner scripts/account_cte_query.rb

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

Implementation notes, for me:
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
