require "json"
require "tmpdir"
require_relative "authorization_fixture"
require_relative "../../scripts/authorization_correctness_gate"

fixture = AuthorizationFixture
Dir.mktmpdir("authorization-correctness-") do |directory|
  manifest = {fixtures: %i[a b].map do |side|
    {name: "msp_#{side}", msp: true, organization_id: fixture.id("msp_#{side}".to_sym),
     targets: {top_level_admin_user_id: fixture.id("admin_#{side}".to_sym), top_level_account_id: fixture.id("cohort_#{side}".to_sym),
       organization_account_ids: [fixture.id("provider_root_#{side}".to_sym), fixture.id("cohort_#{side}".to_sym)],
       msp_account_id: fixture.id("cohort_#{side}".to_sym), sample_account_ids: [fixture.id("root_#{side}".to_sym)]}}
  end}
  manifest_path = File.join(directory, "manifest.json")
  File.write(manifest_path, JSON.generate(manifest))
  settings = {"MANIFEST" => manifest_path, "BENCHMARK_STACK" => "isolated test",
    "ACCOUNT_SERVICE_BASE_URL" => "http://account-service:80", "ORGANIZATION_SERVICE_BASE_URL" => "http://organization-service:80"}
  gate = AuthorizationCorrectnessGate.new(settings: settings).run(output: File.join(directory, "gate.json"))
  puts "LIVE CORRECTNESS GATE: #{JSON.generate(gate)}"

  # A small rerun of the existing hierarchy comparison driver, with exact
  # parent links specified independently of the service response.
  accounts = {root_a: nil, child_a: :root_a, leaf_a: :child_a}.map do |key, parent|
    {"id" => fixture.id(key), "parent_account_id" => parent && fixture.id(parent)}
  end
  target_ids = %i[child_a leaf_a].map { |key| fixture.id(key) }
  expected = {target_ids.first => accounts.first(2), target_ids.last => accounts}
  http = AuthorizationCorrectnessGate.new(settings: settings)
  %w[individual batch].each do |mode|
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    replies = if mode == "individual"
      target_ids.map { |target| http.request("ACCOUNT_SERVICE", "/account_with_parents/#{target}", actor: fixture.id(:reader_a)) }
    else
      [http.request("ACCOUNT_SERVICE", "/accounts_with_parents", actor: fixture.id(:reader_a), body: {account_ids: target_ids})]
    end
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
    raise "Small verified benchmark HTTP failure" unless replies.all? { |response| response.code == "200" }
    chains = mode == "individual" ? replies.map { |r| JSON.parse(r.body) } : JSON.parse(replies.first.body)
    normalized = chains.map { |chain| chain.map { |row| row.slice("id", "parent_account_id") } }
    raise "Small verified benchmark identity mismatch" unless normalized == target_ids.map { |target| expected.fetch(target) }
    puts "SMALL VERIFIED HIERARCHY RERUN: #{JSON.generate(mode: mode, actor: fixture.id(:reader_a), target_ids: target_ids, outcome: "ok", duration_seconds: elapsed, request_count: replies.length, returned_identities: normalized)}"
  end
end
