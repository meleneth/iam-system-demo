class CreateCapabilityGrants < ActiveRecord::Migration[8.0]
  def change
    create_table :capability_grants, id: :uuid do |t|
      t.uuid :user_id, null: false
      t.string :permission, null: false
      t.string :scope_type, null: false
      t.uuid :scope_id


      t.timestamps
    end
    add_index :capability_grants, [ :user_id, :permission, :scope_type, :scope_id ], unique: true, name: 'index_capability_grants_on_user_perm_scope'
  end
end
