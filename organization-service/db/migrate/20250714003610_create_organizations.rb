# frozen_string_literal: true

class CreateOrganizations < ActiveRecord::Migration[8.0]
  def change
    create_table :organizations, id: :uuid do |t|
      t.uuid :account_id, index: true
      t.string :name
      t.timestamps
    end
    create_table :organization_accounts, id: :uuid do |t|
      t.uuid :organization_id, index: true
      t.uuid :account_id, index: true
      t.timestamps
    end
  end
end
