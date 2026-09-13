# Uses the normal SNS seeder and each owning service's projection worker.
require Rails.root.join("scripts/demo_user_seeder")
class DemoFixtureCatalog
  def initialize
    @payloads = []
    @manifest = {generated_by: "authorization repair small dev seed", fixtures: []}
    build_deep_chain
    build_massive_fanout("repair_dev_msp_a", 6)
    build_massive_fanout("repair_dev_msp_b", 6)
  end
end
class DemoFixtureArtifacts
  def write!
    FileUtils.mkdir_p(@output_dir)
    File.write(File.join(@output_dir, "fixture_manifest.json"), JSON.pretty_generate(@manifest), mode: "wx")
  end
end
raise "Development only" unless Rails.env.development?
DemoUserSeeder.new(count: 0, queue_url: "http://eventstream:4566/000000000000/user-seed",
  output_dir: "/rails/tmp/demo-fixtures/authorization-repair-20260913-small", random_seed: 13).seed!
