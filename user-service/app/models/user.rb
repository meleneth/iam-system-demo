# frozen_string_literal: true

class User < ApplicationRecord
  validates :account_id, presence: true
end
