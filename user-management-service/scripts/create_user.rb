# frozen_string_literal: true

# Historical entry point, now using the owning services' group seed projection.
require_relative "demo_user_seeder"
DemoUserSeeder.new(
  count: ENV.fetch("USER_COUNT", DEFAULT_USER_COUNT).to_i,
  queue_url: ENV.fetch("USER_SEED_QUEUE_URL", "http://eventstream:4566/000000000000/user-seed"),
  include_fixtures: ENV.fetch("DEMO_SKIP_FIXTURES", "0") != "1",
  dry_run: ENV.fetch("DEMO_DRY_RUN", "0") == "1",
  output_dir: ENV["DEMO_FIXTURE_OUTPUT_DIR"],
  random_seed: ENV["DEMO_RANDOM_SEED"]
).seed!
