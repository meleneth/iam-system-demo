# frozen_string_literal: true
class CreateGroupUsers < ActiveRecord::Migration[8.0]
  def change
    create_table :group_users, id: :uuid do |t|
      t.uuid :group_id, index: true
      t.uuid :user_id, index: true
      t.timestamps
    end
  end
end
