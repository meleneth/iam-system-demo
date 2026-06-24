# frozen_string_literal: true

class MspManagedAccount < ApplicationRecord
  validates :msp_account_id, presence: true
  validates :managed_account_id, presence: true
  validates :managed_account_id, uniqueness: { scope: :msp_account_id }
end
