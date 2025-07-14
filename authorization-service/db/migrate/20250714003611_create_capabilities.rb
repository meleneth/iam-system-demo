# frozen_string_literal: true
class CreateCapabilities < ActiveRecord::Migration[8.0]
  def change
    create_table :capabilities, id: :uuid do |t|
      t.uuid :subject_id, index: true
      t.uuid :account_id, index: true
      t.string :permission
      t.timestamps
    end
  end
end
