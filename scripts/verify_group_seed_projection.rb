# Run with Rails loaded and this repository mounted at /workspace. No queues or
# databases are written: verify the full deterministic catalog before replaying it.
require "set"
require "/workspace/user-management-service/scripts/demo_user_seeder"
require "/workspace/authorization-service/app/workers/grants_create_queue_worker"

catalog = DemoFixtureCatalog.new
worker = GrantsCreateQueueWorker.allocate
accounts = {}
relationships = {}
grant_rows = 0
catalog.payloads.each do |payload|
  event = JSON.parse(JSON.generate(payload))
  account = event.fetch("account")
  org = event.fetch("organization").fetch("id")
  fact = [org, account["parent_account_id"]]
  raise "Conflicting account ownership/parent projection" if accounts.key?(account.fetch("id")) && accounts.fetch(account.fetch("id")) != fact
  accounts[account.fetch("id")] = fact
  member_groups = event.fetch("groups").map { |group| group.fetch("id") }.to_set
  rows = worker.send(:grant_rows, event)
  worker.send(:validate_grant_rows!, rows, event)
  rows.each do |row|
    raise "User-owned or unassigned grant" if row.key?(:user_id) || !member_groups.include?(row.fetch(:group_id))
    raise "Special MSP grant" if row.fetch(:permission).start_with?("msp.")
  end
  grant_rows += rows.length
  if event["msp_account_id"]
    edge = [event.fetch("msp_managed_by_organization_id"), event.fetch("msp_account_id")]
    raise "Conflicting MSP relationship" if relationships.key?(org) && relationships.fetch(org) != edge
    relationships[org] = edge
  end
end
accounts.each_value do |org, parent|
  raise "Physical parent crosses organization boundary" if parent && accounts.fetch(parent).first != org
end
relationships.each do |client_org, (provider_org, provider)|
  raise "Provider account has wrong organization" unless accounts.fetch(provider).first == provider_org
  raise "MSP organization manages itself" if client_org == provider_org
end
puts JSON.pretty_generate(fixtures: catalog.manifest.fetch(:fixtures).size, seed_events: catalog.payloads.size,
  accounts: accounts.size, client_organization_relationships: relationships.size,
  projected_group_grant_rows_before_deduplication: grant_rows, passed: true)
