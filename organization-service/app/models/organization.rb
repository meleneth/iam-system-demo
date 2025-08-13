# frozen_string_literal: true

# app/models/organization.rb

class Organization < ApplicationRecord
  before_validation :assign_default_name, on: :create
  include Mel::Filterable

  filterable_fields :id

  def accounts
    OrganizationAccount.where(organization_id: id)
  end

  private

  def assign_default_name
    if name.blank?
      self.id ||= SecureRandom.uuid
      self.name = "Organization #{id}".truncate(36)
    end
  end
end
