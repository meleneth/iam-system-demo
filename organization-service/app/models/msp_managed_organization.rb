# frozen_string_literal: true

class MspManagedOrganization < ApplicationRecord
  validates :msp_organization_id, presence: true
  validates :msp_account_id, presence: true
  validates :client_organization_id, presence: true
  validates :client_organization_id, uniqueness: true
  validate :msp_account_belongs_to_msp_organization

  private

  def msp_account_belongs_to_msp_organization
    return if msp_organization_id.blank? || msp_account_id.blank?
    return if OrganizationAccount.exists?(organization_id: msp_organization_id, account_id: msp_account_id)

    errors.add(:msp_account_id, "must belong to the MSP organization")
  end
end
