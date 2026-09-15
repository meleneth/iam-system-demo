require 'minitest/autorun'
require 'tmpdir'
require_relative '../user-management-service/scripts/demo_user_seeder'

class LimitedSeedTest < Minitest::Test
  def test_limited_catalog_preserves_full_fixture_identities_and_adds_isolated_msp
    full = DemoFixtureCatalog.new
    limited = DemoFixtureCatalog.new(profile: 'limited')
    assert_equal 15_526, limited.payloads.size
    assert_equal %w[deep_chain wide_org massive_fanout_10k trace_isolation_msp], limited.manifest[:fixtures].map { |f| f[:name] }
    limited.manifest[:fixtures].first(3).each do |fixture|
      assert_equal full.manifest[:fixtures].find { |f| f[:name] == fixture[:name] }, fixture
    end
    msps = limited.manifest[:fixtures].select { |f| f[:msp] }
    assert_equal 2, msps.size
    refute_equal msps[0][:organization_id], msps[1][:organization_id]
  end

  def test_limited_seed_has_no_filler_and_writes_only_available_examples
    Dir.mktmpdir do |directory|
      seeder = DemoUserSeeder.new(profile: 'limited', queue_url: 'unused', dry_run: true, output_dir: directory, random_seed: 1)
      sent = []
      seeder.define_singleton_method(:send_payload) { |payload| sent << payload }
      capture_io { seeder.seed! }
      assert_equal 15_526, sent.size
      assert sent.all? { |payload| payload[:fixture] }
      manifest = JSON.parse(File.read(File.join(directory, 'fixture_manifest.json')))
      assert_equal 'limited', manifest.fetch('profile')
      %w[rest_curl_examples.sh graphql_curl_examples.sh].each do |file|
        assert system('bash', '-n', File.join(directory, file))
      end
      links = File.read(File.join(directory, 'demo_query_links.md'))
      assert_includes links, '/demo_queries/deep-chain'
      assert_includes links, '/demo_queries/massive-fanout-10k'
      refute_includes links, '50k'
      refute_includes links, '100k'
      refute_includes File.read(File.join(directory, 'rest_curl_examples.sh')), 'IAM_SYSTEM'
    end
  end

  def test_invalid_profiles_and_filler_overrides_fail_before_publishing
    assert_raises(ArgumentError) { DemoUserSeeder.new(profile: 'typo', queue_url: 'unused') }
    assert_raises(ArgumentError) { DemoUserSeeder.new(profile: 'limited', count: 1_000_000, queue_url: 'unused') }
    assert_raises(ArgumentError) { DemoUserSeeder.new(profile: 'limited', include_fixtures: false, queue_url: 'unused') }
  end
end
