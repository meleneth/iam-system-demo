require 'rails_helper'

RSpec.describe "Account hierarchies", type: :request do
  class FakeAccountHierarchyCache
    attr_reader :writes, :sets

    def initialize
      @writes = {}
      @sets = Hash.new { |hash, key| hash[key] = [] }
    end

    def pipelined
      @commands = []
      yield self

      get_commands = @commands.select { |command| command.first == :get }
      get_commands.any? ? Array.new(get_commands.length) : []
    ensure
      @commands = nil
    end

    def get(key)
      @commands << [:get, key]
      nil
    end

    def set(key, value, ex:)
      @commands << [:set, key, value, ex]
      @writes[key] = { value: value, ttl: ex }
    end

    def sadd(key, value)
      @commands << [:sadd, key, value]
      @sets[key] << value
    end
  end

  let(:cache) { FakeAccountHierarchyCache.new }
  let(:organization_id) { SecureRandom.uuid }
  let(:authorization_client) { instance_double(AuthorizedModel::AuthorizationClient) }

  before do
    stub_const("ACCOUNT_CACHE", cache)
    allow(AuthorizedModel).to receive(:authorization_client).and_return(authorization_client)
  end

  def allow_accounts(ids)
    expect(authorization_client).to receive(:capabilities) do |targets|
      expect(targets.map(&:scope_id)).to match_array(Array(ids).map(&:to_s))
      { "Account" => Array(ids).to_h { |id| [id.to_s, ["account.read"]] } }
    end
  end

  it "computes cold account hierarchy misses with one set-based CTE" do
    grandparent = Account.create!(name: "Grandparent")
    parent = Account.create!(name: "Parent", parent_account_id: grandparent.id)
    child_one = Account.create!(name: "Child One", parent_account_id: parent.id)
    child_two = Account.create!(name: "Child Two", parent_account_id: parent.id)
    seed_ids = [grandparent.id, parent.id, child_one.id, child_two.id].map(&:to_s)
    organization = Struct.new(:id).new(organization_id)

    allow(OrganizationAccount).to receive(:account_ids_for_organizations_by_account_ids).with(
      [child_one.id, child_two.id].map(&:to_s)
    ).and_return(
      child_one.id.to_s => { organization: organization, account_ids: seed_ids },
      child_two.id.to_s => { organization: organization, account_ids: seed_ids }
    )
    expect(ActiveRecord::Base.connection).to receive(:exec_query).with(
      kind_of(String),
      "AccountsWithParentsSetCTE",
      kind_of(Array)
    ).once.and_call_original

    post "/accounts_with_parents",
         params: { account_ids: [child_one.id, child_two.id] },
         headers: { "pad-user-id" => "IAM_SYSTEM", "X-IAM-Authorization-Scope" => "iam", "X-IAM-Internal-Token" => ENV.fetch("IAM_INTERNAL_TOKEN") },
         as: :json

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.map { |hierarchy| hierarchy.map { |account| account.fetch("id") } }).to eq(
      [
        [grandparent.id, parent.id, child_one.id].map(&:to_s),
        [grandparent.id, parent.id, child_two.id].map(&:to_s)
      ]
    )
  end

  it "authorizes the real actor for the complete batch before looking up hierarchies" do
    ids = [SecureRandom.uuid, SecureRandom.uuid]
    allow_accounts(ids)
    expect_any_instance_of(AccountsController).to receive(:fetch_accounts_with_parents).with(ids).and_return([])
    post "/accounts_with_parents", params: { account_ids: ids }, headers: { "pad-user-id" => "actor" }, as: :json
    expect(response).to have_http_status(:ok)
  end

  it "denies the entire batch without reading hierarchies when the actor lacks access" do
    ids = [SecureRandom.uuid, SecureRandom.uuid]
    expect(authorization_client).to receive(:capabilities).and_return(
      "Account" => ids.to_h { |id| [id, []] }
    )
    expect_any_instance_of(AccountsController).not_to receive(:fetch_accounts_with_parents)
    post "/accounts_with_parents", params: { account_ids: ids }, headers: { "pad-user-id" => "actor" }, as: :json
    expect(response).to have_http_status(:forbidden)
  end

  it "distinguishes requested account authorization from returned hierarchy authorization" do
    start_id, ancestor_id = SecureRandom.uuid, SecureRandom.uuid
    expect(authorization_client).to receive(:capabilities).ordered.and_return(
      "Account" => { start_id => ["account.read"] }
    )
    expect_any_instance_of(AccountsController).to receive(:fetch_accounts_with_parents).with([start_id])
      .and_return([[{ "id" => ancestor_id }, { "id" => start_id }]])
    expect(authorization_client).to receive(:capabilities).ordered do |targets|
      expect(targets.map(&:scope_id)).to match_array([ancestor_id, start_id])
      { "Account" => { ancestor_id => ["account.read"], start_id => ["account.read"] } }
    end
    post "/accounts_with_parents", params: { account_ids: [start_id] }, headers: { "pad-user-id" => "actor" }, as: :json
    expect(response).to have_http_status(:ok)
  end

  it "bounds cyclic account hierarchies inside the recursive query" do
    first = Account.create!(name: "First")
    second = Account.create!(name: "Second", parent_account_id: first.id)
    first.update_column(:parent_account_id, second.id)
    seed_ids = [first.id, second.id].map(&:to_s)
    organization = Struct.new(:id).new(organization_id)

    allow(OrganizationAccount).to receive(:account_ids_for_organizations_by_account_ids).with(
      [first.id.to_s]
    ).and_return(
      first.id.to_s => { organization: organization, account_ids: seed_ids }
    )

    post "/accounts_with_parents",
         params: { account_ids: [first.id] },
         headers: { "pad-user-id" => "IAM_SYSTEM", "X-IAM-Authorization-Scope" => "iam", "X-IAM-Internal-Token" => ENV.fetch("IAM_INTERNAL_TOKEN") },
         as: :json

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.first.map { |account| account.fetch("id") }).to eq(
      [second.id, first.id].map(&:to_s)
    )
  end

  it "returns an empty hierarchy for an unknown account without an organization lookup" do
    unknown_id = SecureRandom.uuid
    expect(OrganizationAccount).not_to receive(:account_ids_for_organizations_by_account_ids)

    post "/accounts_with_parents",
         params: { account_ids: [unknown_id] },
         headers: { "pad-user-id" => "IAM_SYSTEM", "X-IAM-Authorization-Scope" => "iam", "X-IAM-Internal-Token" => ENV.fetch("IAM_INTERNAL_TOKEN") },
         as: :json

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to eq([[]])
  end
end

RSpec.describe "Account search", type: :request do
  let(:authorization_client) { instance_double(AuthorizedModel::AuthorizationClient) }

  before { allow(AuthorizedModel).to receive(:authorization_client).and_return(authorization_client) }

  it "checks account.read before returning an individual account" do
    account = Account.create!(name: "Customer Account")
    actor_user_id = SecureRandom.uuid

    expect(authorization_client).to receive(:capabilities).and_return(
      "Account" => { account.id.to_s => ["account.read"] }
    )

    get "/accounts/#{account.id}",
        headers: { "pad-user-id" => actor_user_id },
        as: :json

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to include("id" => account.id, "name" => "Customer Account")
  end

  it "ignores stale MSP headers and checks normal account.read authorization" do
    account = Account.create!(name: "Customer Account")
    actor_user_id = SecureRandom.uuid
    msp_account_id = SecureRandom.uuid

    expect(authorization_client).to receive(:capabilities).and_return(
      "Account" => { account.id.to_s => ["account.read"] }
    )

    post "/accounts/search",
         params: { id: [account.id] },
         headers: {
           "pad-user-id" => actor_user_id,
           "pad-msp-account-id" => msp_account_id
         },
         as: :json

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.first).to include("id" => account.id, "name" => "Customer Account")
  end

  it "sends a collection to one batched capability evaluation" do
    account_ids = [SecureRandom.uuid, SecureRandom.uuid]
    expect(authorization_client).to receive(:capabilities).once do |targets|
      expect(targets.map(&:scope_id)).to match_array(account_ids)
      { "Account" => account_ids.to_h { |id| [id, ["account.read"]] } }
    end
    AuthorizationContext.as_requesting_user(user_id: SecureRandom.uuid) do
      Account.authorize_records!(:read, account_ids.map { |id| Account.new(id: id) })
    end
  end
end
