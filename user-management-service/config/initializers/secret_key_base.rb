# config/initializers/secret_key_base.rb

Rails.application.config.secret_key_base = ENV.fetch("RAILS_SECRET_KEY_BASE") unless ENV.key?("SECRET_KEY_BASE_DUMMY")
