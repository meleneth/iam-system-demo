# frozen_string_literal: true
# app/models/account.rb

class Account < ApplicationRecord
  belongs_to :parent_account, class_name: "Account", optional: true
  has_many :child_accounts, class_name: "Account", foreign_key: :parent_account_id, dependent: :nullify
  before_validation :assign_default_name, on: :create

  private

  def assign_default_name
    if name.blank?
      self.id ||= SecureRandom.uuid
      self.name = "Account #{id}".truncate(36)
    end
  end
end
