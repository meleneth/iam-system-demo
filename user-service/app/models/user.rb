# frozen_string_literal: true

class User < ApplicationRecord
  requires_read_capability "account.users.read", scope_type: "Account", target: :account_id, iam: %w[IAM_SYSTEM]
  allows_iam_modify "IAM_SYSTEM"
  include Mel::Filterable

  validates :account_id, presence: true
  filterable_fields :account_id, :id

end
