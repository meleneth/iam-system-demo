class CapabilityGrant < ApplicationRecord
  validates :group_id, :permission, :scope_id, presence: true
  validates :scope_type, inclusion: { in: %w[Account Group Organization] }
end
