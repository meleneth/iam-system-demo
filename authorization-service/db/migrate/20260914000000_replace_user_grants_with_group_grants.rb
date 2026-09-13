# frozen_string_literal: true

class ReplaceUserGrantsWithGroupGrants < ActiveRecord::Migration[8.0]
  def change
    # User grants cannot be safely assigned to groups without changing authority.
    # Preserve them for inspection; replay the explicit group seed projection.
    rename_table :capability_grants, :legacy_user_capability_grants
    create_table :capability_grants, id: :uuid do |t|
      t.uuid :group_id, null: false
      t.string :permission, null: false
      t.string :scope_type, null: false
      t.uuid :scope_id, null: false
      t.timestamps
    end
    add_index :capability_grants, [:group_id, :permission, :scope_type, :scope_id],
              unique: true, name: :index_capability_grants_on_group_permission_scope
    add_check_constraint :capability_grants, "scope_type IN ('Account', 'Group', 'Organization')",
                         name: :capability_grants_known_scope
  end
end
