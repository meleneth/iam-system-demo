# frozen_string_literal: true
require "json"
require "digest/md5"

# Independent expected identities from the deterministic seed contract. Does not
# query /can, capabilities, or privileged enumeration to derive expected access.
module GalleryCorrectness
  def self.uuid(key)
    hex = Digest::MD5.hexdigest("iam-system-demo/#{key}")
    hex[12] = "5"
    hex[16] = ((hex[16].to_i(16) & 3) | 8).to_s(16)
    [hex[0,8], hex[8,4], hex[12,4], hex[16,4], hex[20,12]].join("-")
  end

  def self.exact(actual, expected, label)
    raise "Gallery correctness: #{label} differs" unless actual == expected
  end

  def self.validate(raw, fixture:, batch_size:, graphql:)
    name = fixture.fetch("name")
    msp = !!fixture["msp"]
    customers = msp ? (1...fixture.fetch("account_count")).to_h { |i| [uuid("#{name}/customer/account/#{i}"), i] } : {}
    expected_accounts = msp ? customers.keys.sort.first(batch_size) : fixture.fetch("accounts").map { |a| a.fetch("id") }
    if graphql
      data = JSON.parse(raw).fetch("data")
      page = data.fetch(msp ? "mspUserManagement" : "accountWithParents")
      accounts = msp ? page.fetch("accounts") : page
      if msp
        exact(page.fetch("loading"), false, "loading")
        exact(page.fetch("totalCount"), customers.size, "MSP total")
        exact(page.fetch("loadedCount"), expected_accounts.size, "MSP loaded")
        exact(page.fetch("continuance"), expected_accounts.size < customers.size ? expected_accounts.size.to_s : nil, "MSP cursor")
      end
      users = accounts.flat_map { |a| a.fetch("users").map { |u| u.merge("account_id" => u.fetch("accountId")) } }
      accounts.each { |a| a.fetch("users").each { |u| exact(u.fetch("accountId"), a.fetch("id"), "nested account") } }
    else
      payload = JSON.parse(raw.match(/<script\b[^>]*type=["']application\/json["'][^>]*>(.*?)<\/script>/m)[1])
      accounts, users = payload.fetch("accounts"), payload.fetch("users")
      exact(payload.fetch("organization_id"), fixture.fetch("organization_id"), "organization")
      exact(payload.fetch("actor_user_id"), fixture.fetch("targets").fetch("top_level_admin_user_id"), "actor")
      exact(payload.fetch("total_account_count"), expected_accounts.size, "organization total")
      raise "Gallery fixture exceeds first partition" if expected_accounts.size > batch_size
      users.each { |u| exact(u.fetch("account").fetch("id"), u.fetch("account_id"), "embedded account") }
    end
    exact(accounts.map { |a| a.fetch("id") }.sort, expected_accounts.sort, "Account identities")
    unless msp
      parents = fixture.fetch("accounts").to_h { |a| [a.fetch("id"), a["parent_account_id"]] }
      accounts.each { |a| exact(a.fetch(graphql ? "parentAccountId" : "parent_account_id"), parents.fetch(a.fetch("id")), "parent") }
    end
    expected_users = expected_accounts.flat_map do |account|
      msp ? [[uuid("#{name}/customer/user/#{customers.fetch(account)}"), account, false]] :
        20.times.map { |i| [uuid("#{name}/user/#{account}/#{i}"), account, i.zero?] }
    end
    exact(users.map { |u| [u.fetch("id"), u.fetch("account_id")] }.sort,
      expected_users.map { |id, account, _| [id, account] }.sort, "User identities and scopes")
    admins = expected_users.to_h { |id, _, admin| [id, admin] }
    users.each do |u|
      names = admins.fetch(u.fetch("id")) ? %w[Admins Users] : ["Users"]
      expected_groups = names.map { |group| [uuid("#{name}/group/#{u.fetch('account_id')}/#{group}"), group] }.sort
      exact(u.fetch("groups").map { |g| [g.fetch("id"), g.fetch("name")] }.sort, expected_groups, "Group memberships")
    end
    {"passed" => true, "account_ids" => expected_accounts, "users" => users.size,
      "checks" => "Exact accounts, parents, users, account scopes, group memberships, and available totals/cursor; independent deterministic seed identities"}
  end
end
