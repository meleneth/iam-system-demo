require "test_helper"

class MspUserManagementTest < ActiveSupport::TestCase
  MSP_ACCOUNT_ID = "00000000-0000-0000-0000-000000000003"
  ACTOR_USER_ID = "00000000-0000-0000-0000-000000000004"
  MSP_ORGANIZATION_ID = "00000000-0000-0000-0000-000000000001"
  MANAGED_ACCOUNT_ID = "00000000-0000-0000-0000-000000000002"

  test "loads MSP user management when actor has msp.admin.users on the MSP organization" do
    with_msp_page
    with_capabilities(["msp.admin.users"])

    result = execute_msp_query

    assert_nil result["errors"], result.inspect
    payload = result.fetch("data").fetch("mspUserManagement")
    assert_equal 1, payload.fetch("totalCount")
    assert_equal MANAGED_ACCOUNT_ID, payload.fetch("accounts").first.fetch("id")
  ensure
    restore_stubs
  end

  test "rejects MSP user management when actor lacks msp.admin.users on the MSP organization" do
    with_msp_page
    with_capabilities([])

    result = execute_msp_query

    assert_match(/Not authorized for MSP organization/, result.fetch("errors").first.fetch("message"))
  ensure
    restore_stubs
  end

  private

  def execute_msp_query
    UserManagementServiceSchema.execute(<<~GRAPHQL).to_h
      {
        mspUserManagement(mspAccountId: "#{MSP_ACCOUNT_ID}", as: "#{ACTOR_USER_ID}") {
          totalCount
          accounts {
            id
          }
        }
      }
    GRAPHQL
  end

  def with_msp_page
    save_original(:MspManagedOrganization, :page)
    MspManagedOrganization.define_singleton_method(:page) do |msp_account_id, continuance: nil|
      {
        "msp_organization_id" => MSP_ORGANIZATION_ID,
        "msp_account_id" => msp_account_id,
        "managed_account_ids" => [MANAGED_ACCOUNT_ID],
        "total_count" => 1,
        "continuance" => nil
      }
    end
  end

  def with_capabilities(capabilities)
    save_original(:CapabilityGrant, :capabilities)
    CapabilityGrant.define_singleton_method(:capabilities) do |scope_type, scope_id, user_id:|
      raise "wrong scope #{scope_type}/#{scope_id}" unless scope_type == "Organization" && scope_id == MSP_ORGANIZATION_ID
      raise "wrong user #{user_id}" unless user_id == ACTOR_USER_ID

      capabilities
    end
  end

  def save_original(class_name, method_name)
    @original_methods ||= {}
    key = [class_name, method_name]
    return if @original_methods.key?(key)

    @original_methods[key] = class_name.to_s.constantize.method(method_name)
  end

  def restore_stubs
    Array(@original_methods).each do |(class_name, method_name), original_method|
      klass = class_name.to_s.constantize
      klass.define_singleton_method(method_name) do |*args, **kwargs, &block|
        original_method.call(*args, **kwargs, &block)
      end
    end
  end
end
