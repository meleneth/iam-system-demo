# frozen_string_literal: true

# app/models/organization_accounts.rb

class OrganizationAccount < ApplicationRecord
  requires_read_capability "organization.read.accounts", scope_type: "Organization", target: :organization_id, iam: %w[IAM_SYSTEM]
  requires_read_capability "account.read", scope_type: "Account", target: :account_id
  allows_iam_modify "IAM_SYSTEM"
  include Mel::Filterable

  belongs_to :organization, class_name: "Organization", optional: false
  validates :account_id, presence: true, uniqueness: true
  filterable_fields :account_id, :organization_id
end
