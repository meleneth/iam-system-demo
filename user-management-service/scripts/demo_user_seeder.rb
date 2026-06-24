# frozen_string_literal: true

require 'aws-sdk-sns'
require 'aws-sdk-sqs'
require 'digest/md5'
require 'fileutils'
require 'json'
require 'securerandom'

# id=arn:aws:sns:us-east-1:000000000000:user_seed
MAX_QUEUE_BEFORE_WAIT_FOR_DRAIN = 10_000
DEFAULT_PROGRESS_INTERVAL = 1_000
STANDARD_FIXTURE_USERS_PER_ACCOUNT = 20
LARGE_MANIFEST_SAMPLE_LIMIT = 500

class DemoUserSeeder
  def initialize(count: 1000, queue_url:, include_fixtures: true, dry_run: false, output_dir: nil, random_seed: nil)
    @count = count
    @queue_url = queue_url
    @include_fixtures = include_fixtures
    @dry_run = dry_run
    @output_dir = output_dir
    @random = random_seed ? Random.new(random_seed.to_i) : Random.new

    # only accounts that have no parent_account_id have an organization
    # all others inherit their org from their parent account (tracing all the way up)
    @account_organization = {}
    @existing_accounts = {}
    @existing_account_ids = []
    @account_groups = {}
    @sns = nil
    unless @dry_run
      @sns = Aws::SNS::Client.new(
        region: 'us-east-1',
        endpoint: 'http://eventstream:4566',
        access_key_id: 'fake',
        secret_access_key: 'fake'
      )
    end
  end

  def seed!
    $stdout.sync = true

    puts "Building fixture payloads..."
    catalog = DemoFixtureCatalog.new
    fixture_payloads = @include_fixtures ? catalog.payloads : []
    random_count = [@count - fixture_payloads.length, 0].max

    if @include_fixtures
      DemoFixtureArtifacts.new(catalog.manifest, output_dir).write!
      puts "Generated #{fixture_payloads.length} fixture jobs and wrote demo files to #{output_dir}"
    end

    if fixture_payloads.length > @count
      puts "USER_COUNT=#{@count} is smaller than fixture job count=#{fixture_payloads.length}; publishing all fixtures."
    end

    total_count = fixture_payloads.length + random_count
    started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    fixture_stream = StreamingFixtureScheduler.new(fixture_payloads, total_count, random: @random)
    puts "Streaming #{random_count} random jobs and #{fixture_payloads.length} fixture jobs#{@dry_run ? ' (dry run)' : ''}..."

    published = 0
    random_index = 0

    while published < total_count
      payload = fixture_stream.next_payload(published)
      if !payload && random_index < random_count
        payload = build_user_payload(random_index)
        random_index += 1
      end
      payload ||= fixture_stream.next_payload(published, force: true)

      published += 1
      payload[:index] = published - 1
      send_payload(payload)
      log_progress(published, total_count, started_at)
      maybe_wait_for_grants_queue(published)
    end

    while (payload = fixture_stream.next_payload(total_count, force: true))
      published += 1
      payload[:index] = published - 1
      send_payload(payload)
      log_progress(published, published, started_at)
      maybe_wait_for_grants_queue(published)
    end

    wait_for_seed_queues_to_drain(published) unless @dry_run

    mode = @dry_run ? 'dry-run generated' : 'seeded'
    puts "\nDone: #{mode} #{published} jobs"
  end

  private

  def output_dir
    @output_dir || ENV.fetch('DEMO_FIXTURE_OUTPUT_DIR', '/rails/tmp/demo-fixtures/latest')
  end

  def progress_interval
    ENV.fetch('DEMO_PROGRESS_INTERVAL', DEFAULT_PROGRESS_INTERVAL).to_i.clamp(1, 1_000_000)
  end

  def log_progress(published, total_count, started_at)
    return unless (published % progress_interval).zero? || published == total_count

    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at
    rate = elapsed.positive? ? (published / elapsed).round(1) : published
    puts "Published #{published}/#{total_count} jobs (#{rate} jobs/sec)"
  end

  def maybe_wait_for_grants_queue(published)
    return if @dry_run
    return unless published.positive? && (published % MAX_QUEUE_BEFORE_WAIT_FOR_DRAIN == 0)

    puts "Seeded #{published} users, waiting for grants queue to drain..."
    wait_for_grants_create_to_drain(published)
  end

  def wait_for_grants_create_to_drain(queued_count)
    wait_for_queue_drain(
      queued_count,
      'grants_create' => 'http://eventstream:4566/000000000000/grants_create'
    )
  end

  def wait_for_seed_queues_to_drain(queued_count)
    return if ENV.fetch('DEMO_WAIT_FOR_QUEUES', '1') == '0'

    puts "Published #{queued_count} jobs, waiting for seed queues to drain before declaring the fixtures ready..."
    wait_for_queue_drain(
      queued_count,
      'organization_create' => 'http://eventstream:4566/000000000000/organization_create',
      'account_create' => 'http://eventstream:4566/000000000000/account_create',
      'user_create' => 'http://eventstream:4566/000000000000/user_create',
      'group_create' => 'http://eventstream:4566/000000000000/group_create',
      'grants_create' => 'http://eventstream:4566/000000000000/grants_create'
    )
  end

  def wait_for_queue_drain(queued_count, queue_urls)
    client = Aws::SQS::Client.new(
      region: 'us-east-1',
      endpoint: 'http://eventstream:4566',
      access_key_id: 'fake',
      secret_access_key: 'fake'
    )

    loop do
      remaining_by_queue = queue_urls.transform_values do |queue_url|
        attrs = client.get_queue_attributes(
          queue_url: queue_url,
          attribute_names: ['ApproximateNumberOfMessages']
        )

        attrs.attributes['ApproximateNumberOfMessages'].to_i
      end

      break if remaining_by_queue.values.all?(&:zero?)

      remaining = remaining_by_queue.map { |name, count| "#{name}=#{count}" }.join(', ')
      puts "[#{queued_count}] Seed queues still draining: #{remaining}. Sleeping..."
      sleep 5
    end
  end

  def build_user_payload(index)
    @account = nil
    @organization = nil
    @user = nil
    @is_account_admin = false
    @groups = nil

    {
      type: 'demo.user.create',
      index: index,
      user: user,
      account: account,
      organization: organization,
      groups: groups
    }
  end

  def account
    return @account if @account

    @is_account_admin = false
    if reuse_existing_account?
      @account = @existing_accounts[@existing_account_ids.sample(random: @random)]
    else
      @is_account_admin = true
      if create_child_account?
        parent = @existing_accounts[@existing_account_ids.sample(random: @random)]
        @account = { id: SecureRandom.uuid, parent_account_id: parent[:id] }
        track_account(@account)
      else
        @account = { id: SecureRandom.uuid, parent_account_id: nil }
        @organization = { id: SecureRandom.uuid }
        @account_organization[@account[:id]] = @organization[:id]
        track_account(@account)
      end
    end

    @account
  end

  def groups
    return @groups if @groups

    account
    if !@is_account_admin
      @groups = []
      @groups << @account_groups[account[:id]]['Users']
      return @groups
    end

    @groups = []
    @groups << user_group
    @groups << admin_group
    @groups.each do |new_group|
      @account_groups[account[:id]] ||= {}
      @account_groups[account[:id]][new_group[:name]] = new_group
    end
    @groups
  end

  def user_group
    {
      id: SecureRandom.uuid,
      name: 'Users'
    }
  end

  def admin_group
    {
      id: SecureRandom.uuid,
      name: 'Admins'
    }
  end

  def user
    return @user if @user

    user_id = SecureRandom.uuid
    account # makes sure @is_account_admin is correct
    @user = {
      id: user_id,
      email: "user#{user_id[0, 6]}@example.com",
      account_id: account[:id],
      is_admin: @is_account_admin
    }
  end

  def organization
    return @organization if @organization

    a = account
    a = @existing_accounts[a[:parent_account_id]] while a[:parent_account_id]

    @organization = { id: @account_organization[a[:id]] }
  end

  def send_payload(payload)
    return if @dry_run

    @sns.publish(
      topic_arn: 'arn:aws:sns:us-east-1:000000000000:user_seed',
      message: JSON.dump(payload)
    )
  end

  def reuse_existing_account?
    @existing_accounts.any? && @random.rand < 0.40
  end

  def create_child_account?
    @existing_accounts.any? && @random.rand < 0.40
  end

  def track_account(account)
    @existing_accounts[account[:id]] = account
    @existing_account_ids << account[:id]
  end
end

class StreamingFixtureScheduler
  def initialize(payloads, total_count, random:)
    @random = random
    @payloads_by_parent = Hash.new { |hash, key| hash[key] = [] }
    @fixture_account_ids = {}
    @sent_fixture_account_ids = {}
    @ready = []
    @ready_slots = []
    @pending_slots = random_slots(payloads.length, total_count)

    payloads.shuffle(random: @random).each do |payload|
      account_id = payload.fetch(:account).fetch(:id)
      @fixture_account_ids[account_id] = true
      @payloads_by_parent[payload.fetch(:account)[:parent_account_id]] << payload
    end

    release_parent(nil)
    @payloads_by_parent.keys.each do |parent_account_id|
      next if @fixture_account_ids[parent_account_id]

      release_parent(parent_account_id)
    end
  end

  def next_payload(position, force: false)
    move_ready_slots(position, force: force)
    return nil if @ready_slots.empty?

    payload = @ready_slots.delete_at(@random.rand(@ready_slots.length))
    mark_sent(payload)
    payload
  end

  private

  def random_slots(count, total_count)
    return [] if count.zero?

    max_position = [total_count - 1, 0].max
    Array.new(count) { @random.rand(max_position + 1) }.sort
  end

  def move_ready_slots(position, force:)
    while @ready.any? && (force || @pending_slots.empty? || @pending_slots.first <= position)
      @pending_slots.shift unless @pending_slots.empty?
      @ready_slots << @ready.delete_at(@random.rand(@ready.length))
    end
  end

  def mark_sent(payload)
    account_id = payload.fetch(:account).fetch(:id)
    return if @sent_fixture_account_ids[account_id]

    @sent_fixture_account_ids[account_id] = true
    release_parent(account_id)
  end

  def release_parent(parent_account_id)
    @payloads_by_parent.delete(parent_account_id)&.each do |payload|
      @ready << payload
    end
  end
end

class DemoFixtureCatalog
  attr_reader :payloads, :manifest

  def initialize
    @payloads = []
    @manifest = {
      generated_by: 'user-management-service/scripts/demo_user_seeder.rb',
      fixtures: []
    }

    build_deep_chain
    build_wide_org
    build_dense_account
    build_branching_tree
    build_sparse_enterprise
    build_massive_fanout('massive_fanout_100k', 100_000)
    build_massive_fanout('massive_fanout_50k', 50_000)
    build_massive_fanout('massive_fanout_10k', 10_000)
  end

  private

  def build_deep_chain
    name = 'deep_chain'
    org_id = uuid("#{name}/org")
    accounts = []
    users = []

    parent_id = nil
    25.times do |i|
      account_id = uuid("#{name}/account/#{i}")
      add_account_with_users(name, org_id, account_id, parent_id, accounts, users, user_count: STANDARD_FIXTURE_USERS_PER_ACCOUNT, role_prefix: "level-#{i}")
      parent_id = account_id
    end

    add_fixture(
      name: name,
      description: 'One organization with a 25-level parent account chain.',
      organization_id: org_id,
      accounts: accounts,
      users: users,
      targets: {
        leaf_account_id: accounts.last[:id],
        root_account_id: accounts.first[:id],
        top_level_account_id: accounts.first[:id],
        top_level_admin_user_id: users.first[:id],
        admin_user_id: users.first[:id]
      }
    )
  end

  def build_wide_org
    name = 'wide_org'
    org_id = uuid("#{name}/org")
    root_id = uuid("#{name}/root")
    root_user_id = uuid("#{name}/root-admin")
    accounts = []
    users = []
    add_account_with_users(name, org_id, root_id, nil, accounts, users, user_count: STANDARD_FIXTURE_USERS_PER_ACCOUNT, role_prefix: 'root')

    250.times do |i|
      account_id = uuid("#{name}/account/#{i}")
      add_account_with_users(name, org_id, account_id, root_id, accounts, users, user_count: STANDARD_FIXTURE_USERS_PER_ACCOUNT, role_prefix: "sibling-#{i}")
    end

    add_fixture(
      name: name,
      description: 'One root account with hundreds of sibling child accounts.',
      organization_id: org_id,
      accounts: accounts,
      users: users,
      targets: {
        root_account_id: root_id,
        top_level_account_id: root_id,
        top_level_admin_user_id: users.first[:id],
        sample_account_ids: accounts.last(10).map { |account| account[:id] },
        admin_user_id: users.first[:id]
      }
    )
  end

  def build_dense_account
    name = 'dense_account'
    org_id = uuid("#{name}/org")
    account_id = uuid("#{name}/account")
    teams = 6.times.map { |i| group(name, account_id, "Team #{i}") }
    account_group_list = account_groups(name, account_id) + teams
    accounts = [account_entry(account_id, nil)]
    users = []

    20_000.times do |i|
      admin = i.zero?
      user_id = uuid("#{name}/user/#{i}")
      user_groups = admin ? account_group_list : [group(name, account_id, 'Users'), teams[i % teams.length]]
      users << user_entry(user_id, account_id, admin)
      @payloads << payload(name, account_id, nil, org_id, user_id, admin, user_groups, "user-#{i}")
    end

    add_fixture(
      name: name,
      description: 'One account with many users and multiple groups.',
      organization_id: org_id,
      accounts: accounts,
      users: users,
      groups: account_group_list,
      targets: {
        account_id: account_id,
        top_level_account_id: account_id,
        top_level_admin_user_id: users.first[:id],
        admin_user_id: users.first[:id],
        sample_user_ids: users.last(10).map { |user| user[:id] }
      }
    )
  end

  def build_branching_tree
    name = 'branching_tree'
    org_id = uuid("#{name}/org")
    accounts = []
    users = []
    current_level = [nil]

    4.times do |depth|
      next_level = []
      current_level.each_with_index do |parent_id, parent_index|
        4.times do |child_index|
          next if depth.zero? && parent_index.positive?

          account_id = uuid("#{name}/account/#{depth}/#{parent_index}/#{child_index}")
          add_account_with_users(name, org_id, account_id, parent_id, accounts, users, user_count: STANDARD_FIXTURE_USERS_PER_ACCOUNT, role_prefix: "depth-#{depth}-#{parent_index}-#{child_index}")
          next_level << account_id
        end
      end
      current_level = next_level
    end

    add_fixture(
      name: name,
      description: 'A broad four-level tree for mixed hierarchy and organization scans.',
      organization_id: org_id,
      accounts: accounts,
      users: users,
      targets: {
        root_account_id: accounts.first[:id],
        leaf_account_id: accounts.last[:id],
        top_level_account_id: accounts.first[:id],
        top_level_admin_user_id: users.first[:id],
        admin_user_id: users.first[:id]
      }
    )
  end

  def build_sparse_enterprise
    name = 'sparse_enterprise'
    org_id = uuid("#{name}/org")
    root_id = uuid("#{name}/root")
    root_user_id = uuid("#{name}/root-admin")
    accounts = []
    users = []
    add_account_with_users(name, org_id, root_id, nil, accounts, users, user_count: STANDARD_FIXTURE_USERS_PER_ACCOUNT, role_prefix: 'root')

    400.times do |i|
      account_id = uuid("#{name}/account/#{i}")
      add_account_with_users(name, org_id, account_id, root_id, accounts, users, user_count: STANDARD_FIXTURE_USERS_PER_ACCOUNT, role_prefix: "sparse-account-#{i}")
    end

    add_fixture(
      name: name,
      description: 'Many low-density accounts in one organization.',
      organization_id: org_id,
      accounts: accounts,
      users: users,
      targets: {
        root_account_id: root_id,
        top_level_account_id: root_id,
        top_level_admin_user_id: users.first[:id],
        sample_account_ids: accounts.last(20).map { |account| account[:id] },
        admin_user_id: users.first[:id]
      }
    )
  end

  def build_massive_fanout(name, user_count)
    org_id = uuid("#{name}/org")
    root_id = uuid("#{name}/root")
    root_user_id = uuid("#{name}/root-admin")
    root_groups = account_groups(name, root_id)
    account_samples = [account_entry(root_id, nil)]
    user_samples = [user_entry(root_user_id, root_id, true)]

    @payloads << payload(name, root_id, nil, org_id, root_user_id, true, root_groups, 'root-admin')

    (1...user_count).each do |i|
      account_id = uuid("#{name}/account/#{i}")
      user_id = uuid("#{name}/user/#{i}")
      account_samples << account_entry(account_id, root_id) if sample_index?(i, user_count)
      user_samples << user_entry(user_id, account_id, true) if sample_index?(i, user_count)
      @payloads << payload(name, account_id, root_id, org_id, user_id, true, account_groups(name, account_id), "account-#{i}-admin")
    end

    add_fixture(
      name: name,
      description: "#{user_count} users spread across nearly #{user_count} accounts in one organization.",
      organization_id: org_id,
      account_count: user_count,
      user_count: user_count,
      account_samples: account_samples,
      user_samples: user_samples,
      targets: {
        root_account_id: root_id,
        top_level_account_id: root_id,
        top_level_admin_user_id: root_user_id,
        sample_account_ids: account_samples.last(20).map { |account| account[:id] },
        admin_user_id: root_user_id
      }
    )
  end

  def add_fixture(name:, description:, organization_id:, targets:, accounts: nil, users: nil, account_count: nil, user_count: nil, groups: nil, account_samples: nil, user_samples: nil)
    account_count ||= accounts.length
    user_count ||= users.length
    account_samples ||= sample_collection(accounts)
    user_samples ||= sample_collection(users)

    @manifest[:fixtures] << {
      name: name,
      description: description,
      organization_id: organization_id,
      account_count: account_count,
      user_count: user_count,
      accounts: account_count <= LARGE_MANIFEST_SAMPLE_LIMIT ? accounts : nil,
      account_samples: account_count > LARGE_MANIFEST_SAMPLE_LIMIT ? account_samples : nil,
      users: user_count <= LARGE_MANIFEST_SAMPLE_LIMIT ? users : nil,
      user_samples: user_count > LARGE_MANIFEST_SAMPLE_LIMIT ? user_samples : nil,
      groups: groups,
      targets: targets
    }.compact
  end

  def add_account_with_users(fixture_name, organization_id, account_id, parent_account_id, accounts, users, user_count:, role_prefix:)
    accounts << account_entry(account_id, parent_account_id)
    account_group_list = account_groups(fixture_name, account_id)

    user_count.times do |i|
      admin = i.zero?
      user_id = uuid("#{fixture_name}/user/#{account_id}/#{i}")
      users << user_entry(user_id, account_id, admin)
      user_groups = admin ? account_group_list : [group(fixture_name, account_id, 'Users')]
      @payloads << payload(fixture_name, account_id, parent_account_id, organization_id, user_id, admin, user_groups, "#{role_prefix}-user-#{i}")
    end
  end

  def sample_collection(items)
    return items if items.length <= LARGE_MANIFEST_SAMPLE_LIMIT

    (items.first(10) + items.last(20)).uniq
  end

  def sample_index?(index, total_count)
    index < 10 || index >= total_count - 20
  end

  def payload(fixture_name, account_id, parent_account_id, organization_id, user_id, admin, groups, role)
    {
      type: 'demo.user.create',
      index: nil,
      fixture: fixture_name,
      fixture_role: role,
      user: {
        id: user_id,
        email: "fixture+#{fixture_name}+#{role.tr(' ', '-')}@example.com",
        account_id: account_id,
        is_admin: admin
      },
      account: {
        id: account_id,
        parent_account_id: parent_account_id
      },
      organization: {
        id: organization_id
      },
      groups: groups
    }
  end

  def account_groups(fixture_name, account_id)
    [
      group(fixture_name, account_id, 'Users'),
      group(fixture_name, account_id, 'Admins')
    ]
  end

  def group(fixture_name, account_id, name)
    {
      id: uuid("#{fixture_name}/group/#{account_id}/#{name}"),
      name: name
    }
  end

  def account_entry(id, parent_account_id)
    {
      id: id,
      parent_account_id: parent_account_id
    }
  end

  def user_entry(id, account_id, admin)
    {
      id: id,
      account_id: account_id,
      is_admin: admin
    }
  end

  def uuid(key)
    hex = Digest::MD5.hexdigest("iam-system-demo/#{key}")
    hex[12] = '5'
    hex[16] = ((hex[16].to_i(16) & 0x3) | 0x8).to_s(16)
    "#{hex[0, 8]}-#{hex[8, 4]}-#{hex[12, 4]}-#{hex[16, 4]}-#{hex[20, 12]}"
  end
end

class DemoFixtureArtifacts
  def initialize(manifest, output_dir)
    @manifest = manifest
    @output_dir = output_dir
    @fixtures = manifest.fetch(:fixtures)
  end

  def write!
    FileUtils.mkdir_p(@output_dir)
    File.write(File.join(@output_dir, 'fixture_manifest.json'), JSON.pretty_generate(@manifest))
    File.write(File.join(@output_dir, 'README.md'), readme)
    File.write(File.join(@output_dir, 'rest_curl_examples.sh'), rest_curl_examples)
    File.write(File.join(@output_dir, 'graphql_curl_examples.sh'), graphql_curl_examples)
    File.write(File.join(@output_dir, 'demo_query_links.md'), demo_query_links)
  end

  private

  def readme
    lines = [
      '# Demo Fixture Accounts',
      '',
      'Generated by `user-management-service/scripts/demo_user_seeder.rb`.',
      '',
      'These fixtures are deterministic. Rerunning the seeder produces the same fixture IDs, while publishing fixture jobs in a randomized dependency-safe order.',
      '',
      '## Fixtures',
      ''
    ]

    @fixtures.each do |fixture|
      lines << "### #{fixture.fetch(:name)}"
      lines << fixture.fetch(:description)
      lines << ''
      lines << "- organization_id: `#{fixture.fetch(:organization_id)}`"
      lines << "- account_count: `#{fixture.fetch(:account_count)}`"
      lines << "- user_count: `#{fixture.fetch(:user_count)}`"
      fixture.fetch(:targets).each do |key, value|
        lines << "- #{key}: `#{Array(value).join('`, `')}`"
      end
      lines << ''
    end

    lines << '## Files'
    lines << ''
    lines << '- `rest_curl_examples.sh` contains REST calls with timing output.'
    lines << '- `graphql_curl_examples.sh` contains GraphQL POST examples with timing output.'
    lines << '- `demo_query_links.md` contains browser links that run GraphQL POST requests.'
    lines << '- `fixture_manifest.json` contains the same IDs in machine-readable form.'
    lines << ''
    lines.join("\n")
  end

  def rest_curl_examples
    deep = fixture('deep_chain')
    wide = fixture('wide_org')
    dense = fixture('dense_account')
    branching = fixture('branching_tree')
    sparse = fixture('sparse_enterprise')
    fanout_100k = fixture('massive_fanout_100k')
    fanout_50k = fixture('massive_fanout_50k')
    fanout_10k = fixture('massive_fanout_10k')

    <<~SH
      #!/usr/bin/env bash
      set -euo pipefail

      ACCOUNT_SERVICE="${ACCOUNT_SERVICE:-#{account_service_url}}"
      ORGANIZATION_SERVICE="${ORGANIZATION_SERVICE:-#{organization_service_url}}"
      USER_SERVICE="${USER_SERVICE:-#{user_service_url}}"
      GROUP_SERVICE="${GROUP_SERVICE:-#{group_service_url}}"
      AUTHORIZATION_SERVICE="${AUTHORIZATION_SERVICE:-#{authorization_service_url}}"

      curl_time() {
        curl -sS -o /tmp/iam-demo-response.json -w "time_total=%{time_total}\\n" "$@"
      }

      # Deep ancestry CTE and account cache pressure.
      curl_time -H 'pad-user-id: IAM_SYSTEM' "$ACCOUNT_SERVICE/accounts_with_parents.json?account_ids[]=#{deep.fetch(:targets).fetch(:leaf_account_id)}"

      # Wide organization account-id fan-out.
      curl_time -H 'pad-user-id: #{top_level_admin_user_id(wide)}' "$ORGANIZATION_SERVICE/organization_account_ids/for_account_id/#{wide.fetch(:targets).fetch(:root_account_id)}"

      # Dense user and group counts for a single account.
      curl_time "$USER_SERVICE/accounts/users/counts?account_id[]=#{dense.fetch(:targets).fetch(:account_id)}"
      curl_time "$GROUP_SERVICE/accounts/groups/counts?account_id[]=#{dense.fetch(:targets).fetch(:account_id)}"

      # Branching hierarchy account read through the authorization service.
      curl_time -H 'pad-user-id: #{top_level_admin_user_id(branching)}' "$AUTHORIZATION_SERVICE/can/Account/account.read?scope_id[]=#{branching.fetch(:targets).fetch(:leaf_account_id)}"

      # Sparse enterprise org fan-out.
      curl_time -H 'pad-user-id: #{top_level_admin_user_id(sparse)}' "$ORGANIZATION_SERVICE/organization_account_ids/for_account_id/#{sparse.fetch(:targets).fetch(:root_account_id)}"

      # Massive fan-out organizations.
      curl_time -H 'pad-user-id: #{top_level_admin_user_id(fanout_100k)}' "$ORGANIZATION_SERVICE/organization_account_ids/for_account_id/#{fanout_100k.fetch(:targets).fetch(:root_account_id)}"
      curl_time -H 'pad-user-id: #{top_level_admin_user_id(fanout_50k)}' "$ORGANIZATION_SERVICE/organization_account_ids/for_account_id/#{fanout_50k.fetch(:targets).fetch(:root_account_id)}"
      curl_time -H 'pad-user-id: #{top_level_admin_user_id(fanout_10k)}' "$ORGANIZATION_SERVICE/organization_account_ids/for_account_id/#{fanout_10k.fetch(:targets).fetch(:root_account_id)}"
    SH
  end

  def graphql_curl_examples
    queries.map do |name, query|
      body = JSON.dump(query: query)
      <<~SH
        # #{name}
        curl -sS -o /tmp/iam-demo-graphql-response.json -w "time_total=%{time_total}\\n" \\
          -H 'Content-Type: application/json' \\
          --data '#{body}' \\
          '#{user_management_url}/graphql'

      SH
    end.join
  end

  def demo_query_links
    lines = [
      '# Demo Query Links',
      ''
    ]

    demo_query_paths.each do |name, path|
      lines << "- [#{name}](#{user_management_url}#{path})"
    end

    lines << ''
    lines.join("\n")
  end

  def demo_query_paths
    {
      'Deep chain accountWithParents' => '/demo_queries/deep-chain',
      'Wide organization accounts' => '/demo_queries/wide-org',
      'Dense account users and groups' => '/demo_queries/dense-account',
      'Massive 100k fanout users and groups' => '/demo_queries/massive-fanout-100k',
      'Massive 50k fanout users and groups' => '/demo_queries/massive-fanout-50k',
      'Massive 10k fanout users and groups' => '/demo_queries/massive-fanout-10k'
    }
  end

  def queries
    deep = fixture('deep_chain')
    wide = fixture('wide_org')
    dense = fixture('dense_account')
    branching = fixture('branching_tree')
    fanout_100k = fixture('massive_fanout_100k')
    fanout_50k = fixture('massive_fanout_50k')
    fanout_10k = fixture('massive_fanout_10k')

    {
      'Deep chain accountWithParents' => <<~GRAPHQL,
        {
          accountWithParents(
            id: "#{deep.fetch(:targets).fetch(:leaf_account_id)}"
            as: "#{top_level_admin_user_id(deep)}"
          ) {
            id
            name
            parentAccountId
            users {
              id
              email
              accountId
              groups {
                id
                name
              }
            }
          }
        }
      GRAPHQL
      'Wide organization accounts' => <<~GRAPHQL,
        {
          organization(
            id: "#{wide.fetch(:organization_id)}"
            as: "#{top_level_admin_user_id(wide)}"
          ) {
            id
            name
            accounts {
              id
              name
              users {
                id
                email
                accountId
                groups {
                  id
                  name
                }
              }
            }
          }
        }
      GRAPHQL
      'Dense account users and groups' => <<~GRAPHQL,
        {
          account(
            id: "#{dense.fetch(:targets).fetch(:account_id)}"
            as: "#{top_level_admin_user_id(dense)}"
          ) {
            id
            name
            users {
              id
              email
              accountId
              groups {
                id
                name
              }
            }
          }
        }
      GRAPHQL
      'Branching tree leaf account' => <<~GRAPHQL,
        {
          accountWithParents(
            id: "#{branching.fetch(:targets).fetch(:leaf_account_id)}"
            as: "#{top_level_admin_user_id(branching)}"
          ) {
            id
            name
            parentAccountId
            users {
              id
              email
              accountId
              groups {
                id
                name
              }
            }
          }
        }
      GRAPHQL
      'Massive 100k fanout users and groups' => <<~GRAPHQL,
        {
          organization(
            id: "#{fanout_100k.fetch(:organization_id)}"
            as: "#{top_level_admin_user_id(fanout_100k)}"
          ) {
            id
            name
            accounts {
              id
              users {
                id
                email
                accountId
                groups {
                  id
                  name
                }
              }
            }
          }
        }
      GRAPHQL
      'Massive 50k fanout users and groups' => <<~GRAPHQL,
        {
          organization(
            id: "#{fanout_50k.fetch(:organization_id)}"
            as: "#{top_level_admin_user_id(fanout_50k)}"
          ) {
            id
            name
            accounts {
              id
              users {
                id
                email
                accountId
                groups {
                  id
                  name
                }
              }
            }
          }
        }
      GRAPHQL
      'Massive 10k fanout users and groups' => <<~GRAPHQL
        {
          organization(
            id: "#{fanout_10k.fetch(:organization_id)}"
            as: "#{top_level_admin_user_id(fanout_10k)}"
          ) {
            id
            name
            accounts {
              id
              users {
                id
                email
                accountId
                groups {
                  id
                  name
                }
              }
            }
          }
        }
      GRAPHQL
    }
  end

  def fixture(name)
    @fixtures.find { |fixture| fixture.fetch(:name) == name } || raise("Unknown fixture: #{name}")
  end

  def top_level_admin_user_id(fixture)
    targets = fixture.fetch(:targets)
    targets.fetch(:top_level_admin_user_id) { targets.fetch(:admin_user_id) }
  end

  def user_management_url
    ENV.fetch('USER_MANAGEMENT_BASE_URL', "http://localhost:#{ENV.fetch('USER_MANAGEMENT_WEB_PORT', '7500')}")
  end

  def account_service_url
    ENV.fetch('ACCOUNT_SERVICE_BASE_URL', "http://localhost:#{ENV.fetch('ACCOUNT_SERVICE_WEB_PORT', '11230')}")
  end

  def organization_service_url
    ENV.fetch('ORGANIZATION_SERVICE_BASE_URL', "http://localhost:#{ENV.fetch('ORGANIZATION_SERVICE_WEB_PORT', '11250')}")
  end

  def user_service_url
    ENV.fetch('USER_SERVICE_BASE_URL', "http://localhost:#{ENV.fetch('USER_SERVICE_WEB_PORT', '11220')}")
  end

  def group_service_url
    ENV.fetch('GROUP_SERVICE_BASE_URL', "http://localhost:#{ENV.fetch('GROUP_SERVICE_WEB_PORT', '11115')}")
  end

  def authorization_service_url
    ENV.fetch('AUTHORIZATION_SERVICE_BASE_URL', "http://localhost:#{ENV.fetch('AUTHORIZATION_SERVICE_WEB_PORT', '11240')}")
  end
end

if $PROGRAM_NAME == __FILE__
  queue_url = ENV.fetch('USER_SEED_QUEUE_URL', 'http://eventstream:4566/000000000000/user-seed')
  DemoUserSeeder.new(
    count: ENV.fetch('USER_COUNT', 2_000_000).to_i,
    queue_url: queue_url,
    include_fixtures: ENV.fetch('DEMO_SKIP_FIXTURES', '0') != '1',
    dry_run: ENV.fetch('DEMO_DRY_RUN', '0') == '1',
    output_dir: ENV['DEMO_FIXTURE_OUTPUT_DIR'],
    random_seed: ENV['DEMO_RANDOM_SEED']
  ).seed!
end
