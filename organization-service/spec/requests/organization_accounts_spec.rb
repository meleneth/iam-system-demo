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
  let(:authorization_client) { instance_double(AuthorizedModel::AuthorizationClient) }

  before do
    stub_const("ORGANIZATION_CACHE", FakeOrganizationAccountCache.new)
    allow(AuthorizedModel).to receive(:authorization_client).and_return(authorization_client)
    AuthorizationContext.as_iam do
      Organization.create!(id: organization_id)
      OrganizationAccount.create!(organization_id: organization_id, account_id: account_id)
    end
  end

  def grant_capabilities(*grants)
    allow(authorization_client).to receive(:capabilities) do |targets|
      targets.group_by(&:scope_type).transform_values do |scoped|
        scoped.to_h do |target|
          allowed = grants.include?([target.scope_type, target.scope_id, target.capability])
          [target.scope_id, allowed ? [target.capability] : []]
        end
      end
    end
  end

  it "checks organization.read.accounts before listing accounts by organization" do
    grant_capabilities(["Organization", organization_id, "organization.read.accounts"])

    get "/organization_accounts",
        params: { organization_id: organization_id },
        headers: { "pad-user-id" => actor_user_id }

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.map { |row| row.fetch("account_id") }).to eq([account_id])
  end

  it "rejects noncanonical organization account permissions for relationships, counts, and context" do
    grant_capabilities(["Organization", organization_id, "organization.accounts.read"])

    get "/organization_accounts",
        params: { organization_id: organization_id },
        headers: { "pad-user-id" => actor_user_id }

    expect(response).to have_http_status(:forbidden)

    relationship = AuthorizationContext.as_iam do
      OrganizationAccount.find_by!(account_id: account_id)
    end
    get "/organization_accounts/#{relationship.id}", headers: { "pad-user-id" => actor_user_id }
    expect(response).to have_http_status(:forbidden)

    get "/organizations/accounts/counts/#{organization_id}", headers: { "pad-user-id" => actor_user_id }
    expect(response).to have_http_status(:forbidden)

    post "/organization_account_ids/for_account_ids",
         params: { account_ids: [account_id] },
         headers: { "pad-user-id" => actor_user_id },
         as: :json
    expect(response).to have_http_status(:forbidden)
  end

  it "checks organization.read.accounts before returning account counts" do
    grant_capabilities(["Organization", organization_id, "organization.read.accounts"])

    get "/organizations/accounts/counts/#{organization_id}",
        headers: { "pad-user-id" => actor_user_id }

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to eq(
      "organization_id" => organization_id,
      "accounts_count" => 1
    )
  end

  it "still checks account.read when resolving organization context from account IDs" do
    grant_capabilities(
      ["Account", account_id, "account.read"],
      ["Organization", organization_id, "organization.read.accounts"]
    )

    post "/organization_account_ids/for_account_ids",
         params: { account_ids: [account_id] },
         headers: { "pad-user-id" => actor_user_id },
         as: :json

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.fetch("account_to_organization")).to eq(account_id => organization_id)
  end
  %w[organization account neither].each do |grant_scope|
    it "keeps row and filter lookups equivalent with #{grant_scope} authority" do
      grants = case grant_scope
      when "organization" then [["Organization", organization_id, "organization.read.accounts"]]
      when "account" then [["Account", account_id, "account.read"]]
      else []
      end
      grant_capabilities(*grants)
      relationship = AuthorizationContext.as_iam do
        OrganizationAccount.find_by!(account_id: account_id)
      end
      expected_status = grant_scope == "organization" ? :ok : :forbidden
      get "/organization_accounts/#{relationship.id}", headers: {"pad-user-id" => actor_user_id}
      expect(response).to have_http_status(expected_status)
      [{organization_id: organization_id}, {account_id: account_id},
       {organization_id: organization_id, account_id: account_id}].each do |filters|
        get "/organization_accounts", params: filters, headers: {"pad-user-id" => actor_user_id}
        expect(response).to have_http_status(expected_status)
        expect(response.parsed_body.map { |row| row.fetch("id") }).to eq([relationship.id]) if grant_scope == "organization"
      end
    end
  end

  it "rejects a collection containing a relationship outside the actor's scope" do
    other_account = SecureRandom.uuid
    other_organization = SecureRandom.uuid
    AuthorizationContext.as_iam do
      Organization.create!(id: other_organization)
      OrganizationAccount.create!(organization_id: other_organization, account_id: other_account)
    end
    grant_capabilities(["Organization", organization_id, "organization.read.accounts"])
    get "/organization_accounts", params: {account_id: [account_id, other_account]}, headers: {"pad-user-id" => actor_user_id}
    expect(response).to have_http_status(:forbidden)
  end

end
