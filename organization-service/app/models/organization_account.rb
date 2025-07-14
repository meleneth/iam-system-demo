# frozen_string_literal: true

# app/models/organization_accounts.rb

class OrganizationAccount < ApplicationRecord
  belongs_to :organization, class_name: "Organization", optional: false
  validates :account_id, presence: true
end
