# frozen_string_literal: true
class CreateAccounts < ActiveRecord::Migration[8.0]
  def change
    create_table :accounts, id: :uuid do |t|
      t.string :name
      t.uuid :parent_account_id, index: true

      t.timestamps
    end

    add_foreign_key :accounts, :accounts, column: :parent_account_id
  end
end
