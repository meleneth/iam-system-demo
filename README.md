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
