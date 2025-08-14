# frozen_string_literal: true
class CreateGroups < ActiveRecord::Migration[8.0]
  def change
    create_table :groups, id: :uuid do |t|
      t.uuid :account_id, index: true
      t.string :name
      t.timestamps
    end
  end
end
