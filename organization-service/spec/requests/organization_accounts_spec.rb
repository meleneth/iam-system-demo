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

    post "/organization_account_ids/for_account_ids",
         params: { account_ids: [account_id] },
         headers: { "pad-user-id" => actor_user_id },
         as: :json

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.fetch("account_to_organization")).to eq(account_id => organization_id)
  end
end
