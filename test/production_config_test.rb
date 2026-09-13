require "minitest/autorun"
require_relative "../scripts/check_production_config"

class ProductionConfigTest < Minitest::Test
  def setup
    @prod = { "services" => {} }
    services = @prod["services"]
    ProductionConfig::CONSUMERS.each do |queue, (app, klass, queue_key)|
      env = { "RAILS_ENV" => "production", "SECRET_KEY_BASE" => "demo-secret" }
      ProductionConfig::DATABASE_KEYS.each do |key|
        db = "#{app}-#{key.downcase}"
        env[key] = "postgres://demo:password@#{db}/production"
        services[db] = { "environment" => { "POSTGRES_USER" => "demo", "POSTGRES_PASSWORD" => "password", "POSTGRES_DB" => "production" } }
      end
      services[app] = { "image" => app, "environment" => env }
      services["#{queue}-worker"] = { "image" => app, "command" => ["./bin/rails", "runner", "#{klass}.new.run"],
        "deploy" => { "replicas" => 4 }, "depends_on" => { app => {} }, "environment" => env.merge(queue_key => "http://eventstream:4566/000000000000/#{queue}") }
    end
    @dev = Marshal.load(Marshal.dump(@prod))
    @eventstream = { "Queues" => ProductionConfig::CONSUMERS.keys.map { |q| { "Name" => q } },
      "Topics" => [{ "Name" => "user_seed", "Subscriptions" => ProductionConfig::CONSUMERS.keys.map { |q| { "QueueName" => q } } }] }
  end

  def check
    ProductionConfig.check!(@dev, @prod, @eventstream)
  end

  def group_worker
    @prod["services"]["group_create-worker"]
  end

  def test_complete_config_passes
    assert_equal 30, check
  end

  def test_wrong_worker_replica_count_is_rejected
    group_worker["deploy"]["replicas"] = 2
    assert_match(/expected 4 production worker instances/, assert_raises(RuntimeError) { check }.message)
  end

  def test_replica_count_is_summed_across_named_workers
    group_worker["deploy"]["replicas"] = 2
    @prod["services"]["group_create-worker-peer"] = Marshal.load(Marshal.dump(group_worker))
    assert_equal 31, check
  end

  def test_missing_group_worker_is_rejected_even_if_dev_also_omits_it
    @prod["services"].delete("group_create-worker")
    @dev["services"].delete("group_create-worker")
    assert_match(/No production consumer for group_create/, assert_raises(RuntimeError) { check }.message)
  end

  def test_missing_development_service_is_rejected
    @prod["services"].delete("group_create-worker")
    assert_match(/missing development services/, assert_raises(RuntimeError) { check }.message)
  end

  def test_plural_group_queue_typo_is_rejected
    group_worker["environment"]["GROUPS_SEED_QUEUE_URL"] = "http://eventstream:4566/000000000000/groups_create"
    assert_match(/wrong queue URL/, assert_raises(RuntimeError) { check }.message)
  end

  def test_worker_cannot_inherit_test_environment
    group_worker["environment"]["RAILS_ENV"] = "test"
    assert_match(/RAILS_ENV/, assert_raises(RuntimeError) { check }.message)
  end

  def test_worker_cannot_use_another_database
    group_worker["environment"]["DATABASE_URL"] = "postgres://demo:password@group-service-database_url/development"
    assert_match(/DATABASE_URL/, assert_raises(RuntimeError) { check }.message)
  end

  def test_wrong_database_settings_are_rejected_even_if_worker_matches_app
    @prod["services"]["group-service-database_url"]["environment"]["POSTGRES_DB"] = "other"
    assert_match(/target PostgreSQL/, assert_raises(RuntimeError) { check }.message)
  end

  def test_quoted_worker_secret_is_rejected
    group_worker["environment"]["SECRET_KEY_BASE"] = '"demo-secret"'
    assert_match(/SECRET_KEY_BASE/, assert_raises(RuntimeError) { check }.message)
  end

  def test_wrong_worker_dependency_is_rejected
    group_worker["depends_on"] = { "authorization-service" => {} }
    assert_match(/missing dependency/, assert_raises(RuntimeError) { check }.message)
  end

  def test_unconsumed_subscription_is_rejected
    @eventstream["Topics"][0]["Subscriptions"] << { "QueueName" => "forgotten_queue" }
    assert_match(/coverage mismatch/, assert_raises(RuntimeError) { check }.message)
  end
end
