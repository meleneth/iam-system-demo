# frozen_string_literal: true

# app/models/organization.rb

class Organization < ApplicationRecord
  before_validation :assign_default_name, on: :create

  private

  def assign_default_name
    if name.blank?
      self.id ||= SecureRandom.uuid
      self.name = "Organization #{id}".truncate(36)
    end
  end
end
