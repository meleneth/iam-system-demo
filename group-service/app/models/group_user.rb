# frozen_string_literal: true

class GroupUser < ApplicationRecord
  requires_read_capability "group.read", scope_type: "Group", target: :group_id, iam: %w[IAM_SYSTEM]
  allows_iam_modify "IAM_SYSTEM"
  include Mel::Filterable
  validates :group_id, presence: true
  validates :user_id, presence: true
  filterable_fields :group_id, :user_id, :id
end
