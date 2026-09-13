require "rails_helper"
require "ostruct"

RSpec.describe "Authorization invariant parity" do
  let(:actor) { SecureRandom.uuid }
  let(:group) { SecureRandom.uuid }
  let(:account) { "ab100000-0000-4000-8000-000000000001" }
  let(:redis) { IamDemo::NullRedisCache.new }
  let(:service) { Authorization::Capabilities.new(user_id: actor, redis: redis) }

  before do
    allow_any_instance_of(Authorization::GroupContextClient).to receive(:group_ids_for).with(actor).and_return([group])
    allow(Account).to receive(:with_headers).with("pad-user-id" => "IAM_SYSTEM").and_yield
    allow(Account).to receive(:with_parents_batch) do |ids|
      ids.map { |id| [OpenStruct.new(id: id.downcase, parent_account_id: nil)] }
    end
    allow_any_instance_of(Authorization::AccountContextClient).to receive(:providers_for).and_return({"accounts" => []})
  end

  def grant(scope = account)
    CapabilityGrant.create!(group_id: group, permission: "account.read", scope_type: "Account", scope_id: scope)
  end

  def provider_chain(size)
    ids = Array.new(size) { SecureRandom.uuid }
    edges = ids.each_cons(2).to_h
    grant(ids.last)
    allow_any_instance_of(Authorization::AccountContextClient).to receive(:providers_for) do |_client, account_ids:|
      {"accounts" => account_ids.filter_map { |id| edges[id] && {"account_id" => id, "msp_account_id" => edges.fetch(id)} }}
    end
    ids
  end

  it "allows a provider path at the depth limit individually and in batches" do
    ids = provider_chain(Authorization::Capabilities::MAX_ACCOUNT_HIERARCHY_DEPTH)
    expect(service.for_account(ids.first)).to eq(["account.read"])
    expect(service.account_ids_with_permission(ids.reverse, "account.read")).to eq(ids.to_set)
  end

  it "rejects an over-limit path regardless of which providers are already in the batch" do
    ids = provider_chain(Authorization::Capabilities::MAX_ACCOUNT_HIERARCHY_DEPTH + 1)
    expect { service.for_account(ids.first) }.to raise_error(RuntimeError, "Provider hierarchy exceeds maximum depth")
    [[ids.first], ids.first(2), ids, ids.reverse].each do |batch|
      expect { service.account_ids_with_permission(batch, "account.read") }.to raise_error(RuntimeError, "Provider hierarchy exceeds maximum depth")
    end
    expect(service.for_account(ids[1])).to eq(["account.read"])
  end

  it "enforces the same depth boundary when the last provider has missing hierarchy facts" do
    ids = provider_chain(Authorization::Capabilities::MAX_ACCOUNT_HIERARCHY_DEPTH + 1)
    allow(Account).to receive(:with_parents_batch) do |batch|
      (batch - [ids.last]).map { |id| [OpenStruct.new(id: id, parent_account_id: nil)] }
    end
    expect { service.for_account(ids.first) }.to raise_error(RuntimeError, "Provider hierarchy exceeds maximum depth")
    expect { service.account_ids_with_permission(ids, "account.read") }.to raise_error(RuntimeError, "Provider hierarchy exceeds maximum depth")
  end

  it "matches canonical hierarchy UUIDs while preserving requested IDs in /can results" do
    grant
    expect(service.for_account(account.upcase)).to eq(["account.read"])
    expect(service.for_account(account)).to eq(["account.read"])
    expect(service.account_ids_with_permission([account.upcase, account], "account.read")).to eq(Set[account.upcase, account])
    expect(service.account_ids_with_permission([account.upcase], "account.delete")).to be_empty
  end

  it "resolves uppercase group IDs against canonical ownership facts" do
    target = "bc100000-0000-4000-8000-000000000001"
    grant
    allow_any_instance_of(Authorization::GroupContextClient).to receive(:groups).with([target]).and_return([{"id" => target, "account_id" => account}])
    expect(service.for_group(target.upcase)).to eq(["account.read"])
  end

  [:read, :write].each do |failure|
    context "when Redis #{failure}s fail" do
      let(:redis) { double("Redis", redis_enabled?: true) }
      before do
        allow(redis).to receive(:get).and_return(nil)
        allow(redis).to receive(:set).and_return("OK")
        allow(redis).to receive(:pipelined).and_raise(Redis::BaseError, "unavailable")
        allow(redis).to receive(failure == :read ? :get : :set).and_raise(Redis::BaseError, "unavailable")
      end

      it "preserves both allowed and denied authoritative answers" do
        grant
        other = SecureRandom.uuid
        expect(service.for_account(account)).to eq(["account.read"])
        expect(service.for_account(other)).to eq([])
        expect(service.account_ids_with_permission([account, other], "account.read")).to eq(Set[account])
        expect(service.for_organization(other)).to eq([])
      end

      it "does not swallow an authoritative membership failure" do
        grant
        allow_any_instance_of(Authorization::GroupContextClient).to receive(:group_ids_for).and_raise(IOError, "membership unavailable")
        expect { service.for_account(account) }.to raise_error(IOError, "membership unavailable")
      end
    end
  end
end
