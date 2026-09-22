require "rails_helper"
require "ostruct"

RSpec.describe "Group-owned grants" do
  let(:actor) { SecureRandom.uuid }
  let(:peer) { SecureRandom.uuid }
  let(:outsider) { SecureRandom.uuid }
  let(:readers) { SecureRandom.uuid }
  let(:writers) { SecureRandom.uuid }
  let(:account) { SecureRandom.uuid }
  let(:other_account) { SecureRandom.uuid }
  let(:target_group) { SecureRandom.uuid }
  let(:memberships) { {actor => [readers, writers], peer => [readers], outsider => []} }
  let(:groups) { instance_double(Authorization::GroupContextClient) }
  let(:providers) { instance_double(Authorization::AccountContextClient, providers_for: {"accounts" => []}) }

  def service(user = actor)
    Authorization::Capabilities.new(user_id: user, redis: IamDemo::NullRedisCache.new, group_context_client: groups, account_context_client: providers)
  end

  def grant(group, permission, scope = account, type = "Account")
    CapabilityGrant.create!(group_id: group, permission: permission, scope_type: type, scope_id: scope)
  end

  before do
    allow(groups).to receive(:group_ids_for) { |user| memberships.fetch(user, []) }
    allow(groups).to receive(:groups).with([target_group]).and_return([{"id" => target_group, "account_id" => account}])
    allow(Account).to receive(:with_parents_batch) { |ids| ids.map { |id| [OpenStruct.new(id: id, parent_account_id: nil)] } }
  end

  it "shares a grant between members and denies a nonmember" do
    grant(readers, "account.users.read")
    expect(service.for_account(account)).to eq(["account.users.read"])
    expect(service(peer).for_account(account)).to eq(["account.users.read"])
    expect(service(outsider).for_account(account)).to eq([])
    expect(service(outsider).account_ids_with_permission([account], "account.users.read")).to be_empty
  end

  it "unions grants from multiple groups without borrowing a nonmember group's grants" do
    grant(readers, "account.users.read")
    grant(writers, "account.users.create")
    grant(SecureRandom.uuid, "account.delete")
    expect(service.for_account(account)).to eq(%w[account.users.create account.users.read])
    expect(service(peer).for_account(account)).to eq(["account.users.read"])
  end

  it "requires an explicit membership, independently of an existing grant" do
    grant(readers, "account.users.read")
    memberships[actor] = []
    expect(service.for_account(account)).to eq([])
    memberships[actor] = [readers]
    expect(service.for_account(account)).to eq(["account.users.read"])
  end

  it "requires a grant independently of membership" do
    expect(service.for_account(account)).to eq([])
  end

  it "does not combine a permission in one scope with another group's unrelated scope" do
    grant(readers, "account.users.read", other_account)
    grant(writers, "account.users.create", account)
    expect(service.account_ids_with_permission([account, other_account], "account.users.read")).to eq(Set[other_account])
  end

  it "combines exact-group and inherited account grants only on the actual group" do
    grant(readers, "group.read", target_group, "Group")
    grant(writers, "group.modify", account)
    grant(readers, "group.delete", SecureRandom.uuid, "Group")
    expect(service.for_group(target_group)).to eq(%w[group.modify group.read])
    expect(service.for_account(account)).to eq(["group.modify"])
    expect(service(outsider).for_group(target_group)).to eq([])
  end

  it "fails closed if membership lookup fails" do
    grant(readers, "account.users.read")
    allow(groups).to receive(:group_ids_for).and_raise(IOError, "membership service unavailable")
    expect { service.for_account(account) }.to raise_error(IOError)
  end

  it "fails closed for a cyclic virtual provider graph" do
    grant(readers, "account.users.read")
    allow(providers).to receive(:providers_for) do |account_ids:|
      {"accounts" => account_ids.map { |id| {"account_id" => id, "msp_account_id" => id == account ? other_account : account} }}
    end
    expect(service.for_account(account)).to eq([])
    expect(service.account_ids_with_permission([account, other_account], "account.users.read")).to be_empty
  end

  it "keeps decisions equal when a provider and its client are requested together" do
    grant(readers, "account.users.read", other_account)
    allow(providers).to receive(:providers_for) do |account_ids:|
      {"accounts" => account_ids.include?(account) ? [{"account_id" => account, "msp_account_id" => other_account}] : []}
    end
    expect(service.for_account(account)).to eq(["account.users.read"])
    expect(service.account_ids_with_permission([account, other_account], "account.users.read")).to eq(Set[account, other_account])
  end
end
