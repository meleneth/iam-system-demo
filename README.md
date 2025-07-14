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
