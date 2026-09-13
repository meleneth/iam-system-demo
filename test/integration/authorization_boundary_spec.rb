require "rspec/core"
require "net/http"
require "json"
require_relative "authorization_fixture"

RSpec.describe "Persisted cross-service authorization boundaries" do
  def id(key) = AuthorizationFixture.id(key)
  def request(service, path, actor: :admin_a, body: nil)
    uri = URI("http://#{service}:80#{path}")
    req = body ? Net::HTTP::Post.new(uri) : Net::HTTP::Get.new(uri)
    req["pad-user-id"] = id(actor) if actor
    req["Content-Type"] = "application/json"
    req.body = body.to_json if body
    Net::HTTP.start(uri.hostname, uri.port, open_timeout: 5, read_timeout: 30) { |http| http.request(req) }
  end
  def parsed(response) = JSON.parse(response.body)
  def expect_denied(response)
    expect(response.code.to_i).to eq(403), "expected forbidden, received #{response.code}: #{response.body.to_s[0, 300]}"
  end

  it "allows the actor's organization and denies a mixed organization list across unrelated MSPs" do
    own = request("organization-service", "/organization_accounts?organization_id[]=#{id(:msp_a)}")
    expect(own.code).to eq("200")
    expect(parsed(own).map { |row| row.fetch("account_id") }).to eq([id(:cohort_a)])
    expect_denied(request("organization-service", "/organization_accounts?organization_id[]=#{id(:msp_a)}&organization_id[]=#{id(:msp_b)}"))
  end

  it "authorizes individual organization membership records through the same real primitive" do
    rows = parsed(request("organization-service", "/organization_accounts?organization_id=#{id(:msp_b)}", actor: :admin_b))
    membership_id = rows.fetch(0).fetch("id")
    own = request("organization-service", "/organization_accounts/#{membership_id}", actor: :admin_b)
    expect(parsed(own).fetch("account_id")).to eq(id(:cohort_b))
    expect_denied(request("organization-service", "/organization_accounts/#{membership_id}"))
    expect_denied(request("organization-service", "/organization_accounts/#{membership_id}", actor: nil))
  end

  it "does not treat account read authority as permission to enumerate all organization accounts" do
    expect_denied(request("organization-service", "/organization_account_ids/for_account_ids", actor: :child_reader, body: {account_ids: [id(:child_a)]}))
    allowed = request("organization-service", "/organization_account_ids/for_account_ids", actor: :reader_a, body: {account_ids: [id(:root_a)]})
    expect(allowed.code).to eq("200")
    expect(parsed(allowed)).to eq("account_to_organization" => {id(:root_a) => id(:client_a)}, "organizations" => {id(:client_a) => %i[root_a child_a leaf_a sibling_a extra_a].map { |key| id(key) }})
  end

  it "keeps mixed account decisions separate across principals, scopes and permissions, cold and warm" do
    2.times do
      response = request("authorization-service", "/capabilities/Account", actor: :child_reader, body: {scope_id: %i[root_a child_a leaf_a sibling_a root_b].map { |key| id(key) }})
      expect(parsed(response)).to eq(%i[root_a child_a leaf_a sibling_a root_b].to_h { |key| [id(key), %i[child_a leaf_a].include?(key) ? %w[account.read account.users.read] : []] })
      %i[member_a wrong_permission wrong_scope admin_b].each do |actor|
        denied = request("authorization-service", "/capabilities/Account/#{id(:child_a)}", actor: actor)
        expect(parsed(denied)).not_to include("account.users.read")
      end
    end
  end

  it "does not disclose parent account objects to an actor authorized only on the child" do
    expect_denied(request("account-service", "/accounts_with_parents", actor: :child_reader, body: {account_ids: [id(:child_a)]}))
    allowed = request("account-service", "/accounts_with_parents", actor: :reader_a, body: {account_ids: [id(:leaf_a)]})
    expect(allowed.code).to eq("200")
    expect(parsed(allowed).flatten.map { |row| row.fetch("id") }).to eq(%i[root_a child_a leaf_a].map { |key| id(key) })
  end

  it "checks real permissions before returning users, groups, searches, and counts" do
    2.times do
      %w[user-service group-service].each do |service|
        resource = service == "user-service" ? "users" : "groups"
        expected = service == "user-service" ? :reader_a : :group_a
        allowed = request(service, "/#{resource}/search", actor: :reader_a, body: {account_id: [id(:root_a)]})
        expect(allowed.code).to eq("200")
        expect(parsed(allowed).map { |row| row.fetch("id") }).to eq([id(expected)])
        expect_denied(request(service, "/#{resource}/search", actor: :reader_a, body: {account_id: [id(:root_a), id(:root_b)]}))
      end
    end
  end
  it "requires both the specific MSP grant and the target's ownership relationship" do
    2.times do
      %i[cohort_a root_a child_a root_a2].each do |target|
        expect(parsed(request("authorization-service", "/capabilities/Account/#{id(target)}"))).to eq(%w[account.read account.users.read])
      end
      expect(parsed(request("authorization-service", "/capabilities/Account/#{id(:root_b)}"))).to eq([])
      expect(parsed(request("authorization-service", "/capabilities/Account/#{id(:root_a)}", actor: :admin_b))).to eq([])
      expect(parsed(request("authorization-service", "/capabilities/Account/#{id(:root_a)}", actor: :role_only))).to eq([])
    end
  end

  it "does not disclose a managed account page or its count on MSP role alone" do
    %i[role_only member_a admin_b].each do |actor|
      query = 'query { mspUserManagement(mspAccountId: "' + id(:cohort_a) + '", as: "' + id(actor) + '") { totalCount accounts { id } } }'
      response = parsed(request("user-management-service", "/graphql", body: {query: query}))
      expect(response["data"]).to be_nil
      expect(response.fetch("errors")).not_to be_empty
    end
  end

  it "keeps GraphQL nested fields scoped to each root field's principal" do
    denied_field = 'denied: account(id: "' + id(:root_a) + '", as: "' + id(:wrong_permission) + '") { id users { id } }'
    allowed_field = 'allowed: account(id: "' + id(:root_a) + '", as: "' + id(:reader_a) + '") { id users { id } }'
    [[denied_field, allowed_field], [allowed_field, denied_field]].each do |fields|
      response = parsed(request("user-management-service", "/graphql", body: {query: "query { #{fields.join(' ')} }"}))
      expect(response.fetch("data").fetch("denied")).to be_nil
      expect(response.fetch("data").fetch("allowed")).to eq("id" => id(:root_a), "users" => [{"id" => id(:reader_a)}])
      expect(response.fetch("errors").map { |error| error.fetch("path").first }).to eq(["denied"])
    end
  end

  it "never combines an MSP grant in one organization with an operational grant in another" do
    %i[root_a root_a2 root_b].each do |target|
      response = request("authorization-service", "/capabilities/Account/#{id(target)}", actor: :mixed_actor)
      expect(parsed(response)).to eq([])
    end
    expect(parsed(request("authorization-service", "/capabilities/Account/#{id(:cohort_b)}", actor: :mixed_actor))).to eq(["account.users.read"])
  end

  it "walks all authorized MSP pages without exposing another MSP's identities or metadata" do
    expected_ids = %i[root_a child_a leaf_a sibling_a extra_a root_a2].map { |key| id(key) }.sort
    2.times do
      continuance = nil
      seen = []
      loop do
        path = "/msp_managed_organizations/#{id(:cohort_a)}?limit=2"
        path += "&continuance=#{continuance}" if continuance
        page = request("organization-service", path)
        expect(page.code).to eq("200")
        payload = parsed(page)
        expect(payload.fetch("total_count")).to eq(expected_ids.length)
        expect(payload.fetch("msp_organization_id")).to eq(id(:msp_a))
        seen.concat(payload.fetch("managed_account_ids"))
        expect_denied(request("organization-service", path, actor: :admin_b))
        continuance = payload.fetch("continuance")
        break unless continuance
      end
      expect(seen).to eq(expected_ids)
    end
  end

  it "authorizes counts and group memberships for every target after another principal warms caches" do
    2.times do
      %w[users groups].each do |resource|
        service = resource == "users" ? "user-service" : "group-service"
        path = "/accounts/#{resource}/counts"
        allowed = request(service, path, actor: :reader_a, body: {account_id: [id(:root_a), id(:leaf_a)]})
        expect(parsed(allowed)).to eq(id(:root_a) => 1, id(:leaf_a) => 0)
        expect_denied(request(service, path, actor: :reader_b, body: {account_id: [id(:root_a)]}))
        expect_denied(request(service, path, actor: :reader_a, body: {account_id: [id(:root_a), id(:root_b)]}))
      end
      allowed = request("group-service", "/group_users/search", actor: :reader_a, body: {group_id: [id(:group_a)]})
      expect(parsed(allowed).map { |row| row.fetch("id") }).to eq([id(:membership_a)])
      expect_denied(request("group-service", "/group_users/search", actor: :reader_a, body: {group_id: [id(:group_a), id(:group_b)]}))
    end
  end

  it "treats missing context as failure and empty searches as empty, never unrestricted" do
    %i[reader_a reader_b].each do |actor|
      response = request("user-service", "/users/search", actor: actor, body: {id: []})
      expect(parsed(response)).to eq([])
    end
    response = request("authorization-service", "/can/Account/account.read", body: {})
    expect(response.code).to eq(ENV["AUTHORIZATION_CHECK_MODE"] == "capabilities" ? "503" : "400")
    response = request("authorization-service", "/capabilities/Account/#{id(:root_a)}", actor: nil)
    expect(response.code).to eq("400")
    expect_denied(request("organization-service", "/msp_managed_organizations/00000000-0000-4000-8000-000000000000"))
  end

  it "does not discover and impersonate a target organization's administrator in the demo frontdoor" do
    path = "/frontdoor/random_record/#{id(:msp_a)}/#{id(:cohort_a)}"
    own = request("user-management-service", path + "?as=#{id(:admin_a)}")
    expect(own.code).to eq("200")
    expect(own.body).to include(id(:cohort_a))
    expect_denied(request("user-management-service", path + "?as=#{id(:admin_b)}", actor: :admin_b))
  end

  it "keeps the HTML organization partition and account view scoped to their explicit actor" do
    path = "/organization_user_management/partition?organization_id=#{id(:msp_a)}"
    own = request("user-management-service", path + "&as=#{id(:admin_a)}")
    expect(own.code).to eq("200")
    raw = own.body.match(/<script[^>]*type=['"]application\/json['"][^>]*>(.*?)<\/script>/m)[1]
    payload = JSON.parse(raw)
    expect(payload.fetch("accounts").map { |row| row.fetch("id") }).to eq([id(:cohort_a)])
    expect(payload.fetch("users").map { |row| row.fetch("id") }.sort).to eq(%i[admin_a member_a].map { |key| id(key) }.sort)
    expect(payload.fetch("total_account_count")).to eq(1)
    expect_denied(request("user-management-service", path + "&as=#{id(:admin_b)}"))
    expect_denied(request("user-management-service", "/accounts/#{id(:cohort_a)}?as=#{id(:admin_b)}"))
    expect(request("user-management-service", "/accounts/#{id(:cohort_a)}?as=#{id(:admin_a)}").code).to eq("200")
    expect(request("user-management-service", "/frontdoor/random_record").code).to eq("404")
    expect(request("user-management-service", "/debug").code).to eq("404")
  end

end
