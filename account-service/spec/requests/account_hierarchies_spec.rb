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

  before do
    stub_const("ACCOUNT_CACHE", cache)
  end

  it "computes cold account hierarchy misses with one set-based CTE" do
    grandparent = Account.create!(name: "Grandparent")
    parent = Account.create!(name: "Parent", parent_account_id: grandparent.id)
    child_one = Account.create!(name: "Child One", parent_account_id: parent.id)
    child_two = Account.create!(name: "Child Two", parent_account_id: parent.id)
    seed_ids = [grandparent.id, parent.id, child_one.id, child_two.id].map(&:to_s)
    organization = Struct.new(:id).new(organization_id)

    allow(OrganizationAccount).to receive(:with_headers).and_yield
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
         headers: { "pad-user-id" => "IAM_SYSTEM" },
         as: :json

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.map { |hierarchy| hierarchy.map { |account| account.fetch("id") } }).to eq(
      [
        [grandparent.id, parent.id, child_one.id].map(&:to_s),
        [grandparent.id, parent.id, child_two.id].map(&:to_s)
      ]
    )
  end
end

RSpec.describe "Account search", type: :request do
  FakeFaradayResponse = Struct.new(:status, :body)
  FakeFaradayRequest = Struct.new(:headers, :body, keyword_init: true)

  it "checks account.read before returning an individual account" do
    account = Account.create!(name: "Customer Account")
    actor_user_id = SecureRandom.uuid

    expect(User).to receive(:user_can).with(
      actor_user_id,
      "Account",
      "account.read",
      account.id
    ).and_return(true)

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

    expect(User).to receive(:user_can).with(
      actor_user_id,
      "Account",
      "account.read",
      [account.id.to_s]
    ).and_return(true)

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

  it "checks batched account capabilities instead of calling /can in capabilities-only mode" do
    account_ids = [SecureRandom.uuid, SecureRandom.uuid]
    request = nil
    old_mode = ENV["AUTHORIZATION_CHECK_MODE"]
    ENV["AUTHORIZATION_CHECK_MODE"] = "capabilities"

    expect(Faraday).to receive(:post).with("#{Env::AUTHORIZATION_SERVICE_API_BASE_URL}/capabilities/Account") do |&block|
      request = FakeFaradayRequest.new(headers: {})
      block.call(request)
      FakeFaradayResponse.new(
        200,
        account_ids.to_h { |account_id| [account_id, ["account.read"]] }.to_json
      )
    end

    expect(User.user_can(actor_user_id = SecureRandom.uuid, "Account", "account.read", account_ids)).to eq(true)
    expect(request.headers).to include("pad-user-id" => actor_user_id)
    expect(JSON.parse(request.body)).to eq("scope_id" => account_ids)
  ensure
    ENV["AUTHORIZATION_CHECK_MODE"] = old_mode
  end
end
