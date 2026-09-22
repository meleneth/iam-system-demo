# frozen_string_literal: true

class Group < ApplicationRecord
  requires_read_capability "group.read", scope_type: "Group", target: :id, iam: %w[IAM_SYSTEM]
  requires_read_capability "account.users.read", scope_type: "Account", target: :account_id
  allows_iam_modify "IAM_SYSTEM"
  include Mel::Filterable
  validates :account_id, presence: true
  filterable_fields :account_id, :id, :name
end
