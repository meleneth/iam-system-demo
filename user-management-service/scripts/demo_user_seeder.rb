# frozen_string_literal: true
require 'aws-sdk-sns'
require 'async'
require 'securerandom'
require 'json'

# id=arn:aws:sns:us-east-1:000000000000:user_seed
MAX_QUEUE_BEFORE_WAIT_FOR_DRAIN = 10_000

class DemoUserSeeder
  def initialize(count: 1000, queue_url:)
    @count = count
    @queue_url = queue_url
    # only accounts that have no parent_account_id have an organization
    # all others inherit their org from their parent account (tracing all the way up)
    @account_organization = {}
    @existing_accounts = {}
    @account_groups = {}
    @sns = Aws::SNS::Client.new(
      region: 'us-east-1',
      endpoint: 'http://eventstream:4566',
      access_key_id: 'fake',
      secret_access_key: 'fake'
    )
  end

  def seed!
    (0...@count).each do |i|
      payload = build_user_payload(i)
      send_payload(payload)
      print '.'

      if i > 0 && (i % MAX_QUEUE_BEFORE_WAIT_FOR_DRAIN == 0)
        puts "Seeded #{i} users, waiting for grants queue to drain..."
        wait_for_grants_create_to_drain(i)
      end
    end

    puts "\nDone seeding #{@count} jobs to SNS"
  end

  private

  def wait_for_grants_create_to_drain(queued_count)
    client = Aws::SQS::Client.new(
      region: 'us-east-1',
      endpoint: 'http://eventstream:4566',
      access_key_id: 'fake',
      secret_access_key: 'fake'
    )
    grants_queue_url = "http://eventstream:4566/000000000000/grants_create"
    #ENV.fetch("GRANTS_CREATE_QUEUE_URL")

    loop do
      attrs = client.get_queue_attributes(
        queue_url: grants_queue_url,
        attribute_names: ["ApproximateNumberOfMessages"]
      )

      remaining = attrs.attributes["ApproximateNumberOfMessages"].to_i

      break if remaining == 0

      puts "[#{queued_count}] Grants queue has #{remaining} messages. Sleeping..."
      sleep 5
    end
  end

  def build_user_payload(index)
    @account = nil
    @organization = nil
    @user = nil
    @is_account_admin = false

    {
      type: "demo.user.create",
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
      @account = @existing_accounts.values.sample
    else
      @is_account_admin = true
      if create_child_account?
        parent = @existing_accounts.values.sample
        @account = { id: SecureRandom.uuid, parent_account_id: parent[:id] }
        @existing_accounts[@account[:id]] = @account
      else
        @account = { id: SecureRandom.uuid }
        @organization = { id: SecureRandom.uuid }
        @account_organization[@account[:id]] = @organization[:id]
        @existing_accounts[@account[:id]] = @account
      end
    end

    @account
  end

  def groups
    return @groups if @groups
    account
    return @groups = [@account_groups[account[:id]["Users"]]] unless @is_account_admin
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

    return {
      id: SecureRandom.uuid,
      name: "Users"
    }
  end

  def admin_group
    return {
      id: SecureRandom.uuid,
      name: "Admins"
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
    while(a[:parent_account_id]) do
      a = @existing_accounts[a[:parent_account_id]]
    end

    @organization = { id: @account_organization[a[:id]] }
  end

  def send_payload(payload)
    @sns.publish(
      topic_arn: "arn:aws:sns:us-east-1:000000000000:user_seed",
      message: JSON.dump(payload)
    )
  end

  def reuse_existing_account?
    @existing_accounts.any? && rand < 0.40
  end

  def create_child_account?
    @existing_accounts.any? && rand < 0.40
  end
end

if $PROGRAM_NAME == __FILE__
  queue_url = ENV.fetch('USER_SEED_QUEUE_URL', 'http://eventstream:4566/000000000000/user-seed')
  DemoUserSeeder.new(count: ENV.fetch('USER_COUNT', 10_000).to_i, queue_url: queue_url).seed!
end
