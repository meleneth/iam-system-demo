require "rails_helper"
require "ostruct"

RSpec.describe "Group scope authorization", type: :request do
  class GroupCapabilitiesRedis
    def initialize
      @values = {}
      @pipeline = nil
    end

    def pipelined
      @pipeline = []
      yield self
      @pipeline
    ensure
      @pipeline = nil
    end

    def get(key)
      value = @values[key]
      @pipeline << value if @pipeline
      value
    end

    def set(key, value, ex:)
      @values[key] = value
      @pipeline << "OK" if @pipeline
      "OK"
    end
  end

  it "keeps cold and warm capability and /can decisions equal across legitimate grant origins" do
    actor, member_group, target, sibling, denied, target_account, sibling_account, denied_account =
      Array.new(8) { SecureRandom.uuid }
    CapabilityGrant.create!(group_id: member_group, permission: "group.read", scope_type: "Group", scope_id: target)
    CapabilityGrant.create!(group_id: member_group, permission: "account.users.read", scope_type: "Account", scope_id: sibling_account)
    redis = GroupCapabilitiesRedis.new
    stub_const("AUTHORIZATION_CACHE", redis)
    allow_any_instance_of(Authorization::GroupContextClient).to receive(:group_ids_for).with(actor).and_return([member_group])
    allow_any_instance_of(Authorization::GroupContextClient).to receive(:groups) do |_client, ids|
      owners = {target => target_account, sibling => sibling_account, denied => denied_account}
      ids.filter_map { |id| {"id" => id, "account_id" => owners.fetch(id)} if owners.key?(id) }
    end
    allow_any_instance_of(Authorization::AccountContextClient).to receive(:providers_for).and_return({"accounts" => []})
    allow(Account).to receive(:with_parents_batch) do |ids|
      ids.map { |id| [OpenStruct.new(id: id, parent_account_id: nil)] }
    end
    headers = {"pad-user-id" => actor}
    2.times do
      get "/capabilities/Group/#{target}", headers: headers
      expect(response.parsed_body).to eq(["group.read"])
      get "/capabilities/Group/#{sibling}", headers: headers
      expect(response.parsed_body).to eq(["account.users.read", "group.read"])

      post "/capabilities/Group", params: {scope_id: [target, sibling]}, headers: headers, as: :json
      expect(response.parsed_body).to eq(
        target => ["group.read"], sibling => ["account.users.read", "group.read"]
      )
      post "/can/Group/group.read", params: {scope_id: [target, sibling]}, headers: headers, as: :json
      expect(response).to have_http_status(:ok)

      post "/capabilities/Group", params: {scope_id: [target, sibling, denied]}, headers: headers, as: :json
      expect(response.parsed_body.fetch(denied)).to eq([])
      post "/can/Group/group.read", params: {scope_id: [target, sibling, denied]}, headers: headers, as: :json
      expect(response).to have_http_status(:forbidden)
    end
  end
end
