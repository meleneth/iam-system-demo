# frozen_string_literal: true

class User < ApplicationRecord
  include Mel::Filterable
  validates :account_id, presence: true
  filterable_fields :account_id, :id
end
