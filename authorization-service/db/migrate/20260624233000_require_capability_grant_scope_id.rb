# frozen_string_literal: true

class RequireCapabilityGrantScopeId < ActiveRecord::Migration[8.0]
  def change
    change_column_null :capability_grants, :scope_id, false
  end
end
