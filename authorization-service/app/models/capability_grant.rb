class CapabilityGrant < ApplicationRecord
  validates :user_id, presence: true
  validates :permission, presence: true
  validates :scope_type, presence: true
  validates :scope_id, presence: true
end
