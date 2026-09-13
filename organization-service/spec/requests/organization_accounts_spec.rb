require "rails_helper"
require "securerandom"

RSpec.describe "Organization accounts", type: :request do
  class FakeOrganizationAccountCache
    def pipelined
      @commands = []
      yield self
      @commands.select { |command| command.first == :get }.map { nil }
    ensure
      @commands = nil
    end

    def get(key)
      @commands << [:get, key]
      nil
    end

    def set(key, value, ex:)
      @commands << [:set, key, value, ex]
    end
  end

  let(:actor_user_id) { SecureRandom.uuid }
  let(:organization_id) { SecureRandom.uuid }
  let(:account_id) { SecureRandom.uuid }

  before do
    stub_const("ORGANIZATION_CACHE", FakeOrganizationAccountCache.new)
    Organization.create!(id: organization_id)
    OrganizationAccount.create!(organization_id: organization_id, account_id: account_id)
  end

  it "checks organization.read.accounts before listing accounts by organization" do
    expect(User).to receive(:user_can)
      .with(actor_user_id, "Organization", "organization.read.accounts", organization_id)
      .and_return(true)

    get "/organization_accounts",
        params: { organization_id: organization_id },
        headers: { "pad-user-id" => actor_user_id }

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.map { |row| row.fetch("account_id") }).to eq([account_id])
  end

  it "accepts the legacy organization.accounts.read grant while old seed data exists" do
    expect(User).to receive(:user_can)
      .with(actor_user_id, "Organization", "organization.read.accounts", organization_id)
      .and_return(false)
    expect(User).to receive(:user_can)
      .with(actor_user_id, "Organization", "organization.accounts.read", organization_id)
      .and_return(true)

    get "/organization_accounts",
        params: { organization_id: organization_id },
        headers: { "pad-user-id" => actor_user_id }

    expect(response).to have_http_status(:ok)
  end

  it "checks organization.read.accounts before returning account counts" do
    expect(User).to receive(:user_can)
      .with(actor_user_id, "Organization", "organization.read.accounts", organization_id)
      .and_return(true)

    get "/organizations/accounts/counts/#{organization_id}",
        headers: { "pad-user-id" => actor_user_id }

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to eq(
      "organization_id" => organization_id,
      "accounts_count" => 1
    )
  end

  it "still checks account.read when resolving organization context from account IDs" do
    expect(User).to receive(:user_can)
      .with(actor_user_id, "Account", "account.read", [account_id])
      .and_return(true)

    expect(User).to receive(:user_can)
      .with(actor_user_id, "Organization", "organization.read.accounts", organization_id)
      .and_return(true)

    post "/organization_account_ids/for_account_ids",
         params: { account_ids: [account_id] },
         headers: { "pad-user-id" => actor_user_id },
         as: :json

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.fetch("account_to_organization")).to eq(account_id => organization_id)
  end
  %w[organization account neither].each do |grant_scope|
    it "keeps row and filter lookups equivalent with #{grant_scope} authority" do
      allow(User).to receive(:user_can) do |actor, scope, permission, id|
        actor == actor_user_id && (
          (grant_scope == "organization" && scope == "Organization" && permission == "organization.read.accounts" && id == organization_id) ||
          (grant_scope == "account" && scope == "Account" && permission == "account.read" && id == account_id)
        )
      end
      relationship = OrganizationAccount.find_by!(account_id: account_id)
      expected_status = grant_scope == "neither" ? :forbidden : :ok
      get "/organization_accounts/#{relationship.id}", headers: {"pad-user-id" => actor_user_id}
      expect(response).to have_http_status(expected_status)
      [{organization_id: organization_id}, {account_id: account_id},
       {organization_id: organization_id, account_id: account_id}].each do |filters|
        get "/organization_accounts", params: filters, headers: {"pad-user-id" => actor_user_id}
        expect(response).to have_http_status(expected_status)
        expect(response.parsed_body.map { |row| row.fetch("id") }).to eq([relationship.id]) unless grant_scope == "neither"
      end
    end
  end

  it "rejects a collection containing a relationship outside the actor's scope" do
    other_account = SecureRandom.uuid
    OrganizationAccount.create!(organization_id: organization_id, account_id: other_account)
    allow(User).to receive(:user_can) do |actor, scope, permission, id|
      actor == actor_user_id && scope == "Account" && permission == "account.read" && id == account_id
    end
    get "/organization_accounts", params: {organization_id: organization_id}, headers: {"pad-user-id" => actor_user_id}
    expect(response).to have_http_status(:forbidden)
  end

end
