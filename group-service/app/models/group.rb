# frozen_string_literal: true

class Group < ApplicationRecord
  include Mel::Filterable
  validates :account_id, presence: true
  filterable_fields :account_id, :id, :name
end
