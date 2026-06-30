class DropMspManagedAccounts < ActiveRecord::Migration[8.0]
  def change
    drop_table :msp_managed_accounts do |t|
      t.uuid :msp_account_id, null: false
      t.uuid :managed_account_id, null: false
      t.timestamps null: false
      t.index [:msp_account_id, :managed_account_id], unique: true, name: "idx_msp_managed_accounts_unique_pair"
      t.index :msp_account_id
      t.index :managed_account_id
    end
  end
end
