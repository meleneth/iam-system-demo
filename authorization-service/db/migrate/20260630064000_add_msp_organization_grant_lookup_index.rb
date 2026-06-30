class AddMspOrganizationGrantLookupIndex < ActiveRecord::Migration[8.0]
  def change
    add_index :capability_grants,
              [:user_id, :scope_id, :permission],
              name: "idx_capability_grants_msp_org_lookup",
              where: "scope_type = 'Organization' AND permission LIKE 'msp.%'"
  end
end
