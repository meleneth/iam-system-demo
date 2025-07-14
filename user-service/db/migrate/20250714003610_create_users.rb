# frozen_string_literal: true
class CreateUsers < ActiveRecord::Migration[8.0]
  def change
    create_table :users, id: :uuid do |t|
      t.uuid :account_id, index: true
      t.string :email
      t.string :username
      t.string :first_name
      t.string :last_name
      t.string :middle_name
      t.string :phone_number
      t.string :alt_phone
      t.string :slack_id
      t.string :avatar_url
      t.string :linkedin
      t.string :github
      t.string :twitter
      t.string :tshirt_size
      t.string :pronouns
      t.string :timezone
      t.timestamps
    end
  end
end
