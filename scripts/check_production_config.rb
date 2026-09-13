# frozen_string_literal: true
require "json"
require "open3"
require "uri"
require "yaml"

module ProductionConfig
  # Queue -> owning application, worker class, queue URL variable.
  CONSUMERS = {
    "organization_create" => %w[organization-service OrganizationCreateQueueWorker ORGANIZATION_SEED_QUEUE_URL],
    "account_create" => %w[account-service AccountCreateQueueWorker ACCOUNT_SEED_QUEUE_URL],
    "user_create" => %w[user-service UserCreateQueueWorker USER_SEED_QUEUE_URL],
    "grants_create" => %w[authorization-service GrantsCreateQueueWorker GRANTS_SEED_QUEUE_URL],
    "group_create" => %w[group-service GroupsCreateQueueWorker GROUPS_SEED_QUEUE_URL]
  }.freeze
  DATABASE_KEYS = %w[DATABASE_URL CACHE_DATABASE_URL CABLE_DATABASE_URL QUEUE_DATABASE_URL].freeze

  def self.check!(dev, prod, eventstream)
    services = prod.fetch("services")
    missing = dev.fetch("services").keys - services.keys
    raise "Production missing development services: #{missing.join(', ')}" unless missing.empty?
    queues = eventstream.fetch("Queues").map { |q| q.fetch("Name") }.sort
    subscriptions = eventstream.fetch("Topics").find { |t| t["Name"] == "user_seed" }.fetch("Subscriptions").map { |s| s.fetch("QueueName") }.sort
    raise "Seed queue/subscription coverage mismatch" unless queues == CONSUMERS.keys.sort && subscriptions == queues

    CONSUMERS.each do |queue, (app, worker_class, queue_key)|
      workers = services.select { |_, s| Array(s["command"]).include?("#{worker_class}.new.run") }
      raise "No production consumer for #{queue}" if workers.empty?
      replicas = workers.values.sum { |worker| Integer(worker.fetch("deploy", {}).fetch("replicas", 1)) }
      raise "#{queue}: expected 4 production worker instances, found #{replicas}" unless replicas == 4
      owner = services.fetch(app)
      workers.each do |name, worker|
        env = worker.fetch("environment")
        raise "#{name}: image differs from #{app}" unless worker["image"] == owner["image"]
        raise "#{name}: missing dependency on #{app}" unless worker.fetch("depends_on", {}).key?(app)
        raise "#{name}: wrong queue URL" unless env[queue_key] == "http://eventstream:4566/000000000000/#{queue}"
        (DATABASE_KEYS + ["SECRET_KEY_BASE"]).each do |key|
          raise "#{name}: #{key} differs from #{app}" unless env.fetch(key) == owner.fetch("environment").fetch(key)
        end
      end
    end

    services.each do |name, service|
      env = service.fetch("environment", {})
      next unless env.key?("RAILS_ENV")
      raise "#{name}: RAILS_ENV must be production" unless env["RAILS_ENV"] == "production"
      DATABASE_KEYS.each do |key|
        next unless env[key]
        uri = URI(env[key])
        db = services.fetch(uri.host).fetch("environment")
        expected = [db.fetch("POSTGRES_USER"), db.fetch("POSTGRES_PASSWORD"), db.fetch("POSTGRES_DB")]
        actual = [uri.user, uri.password, uri.path.delete_prefix("/")].map { |v| URI::DEFAULT_PARSER.unescape(v) }
        raise "#{name}: #{key} does not match target PostgreSQL configuration" unless actual == expected
      end
    end
    services.size
  end
end

if $PROGRAM_NAME == __FILE__
  configs = %w[dev prod].map do |stack|
    output, status = Open3.capture2("./dc_#{stack}", "config", "--format", "json")
    raise "Cannot resolve #{stack}" unless status.success?
    JSON.parse(output)
  end
  count = ProductionConfig.check!(*configs, YAML.load_file("eventstream/goaws.yaml").fetch("Local"))
  puts "Checked #{count} production services: development parity, all five seed queues, worker ownership, production mode and database targets."
end
