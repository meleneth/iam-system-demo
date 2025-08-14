# frozen_string_literal: true

class GroupUser < ApplicationRecord
  include Mel::Filterable
  validates :group_id, presence: true
  validates :user_id, presence: true
  filterable_fields :group_id, :user_id, :id
end
