class CapabilityGrant < ApplicationRecord
  allows_iam_read "IAM_SYSTEM"
  allows_iam_modify "IAM_SYSTEM"
  validates :group_id, :permission, :scope_id, presence: true
  validates :scope_type, inclusion: { in: %w[Account Group Organization] }
end
