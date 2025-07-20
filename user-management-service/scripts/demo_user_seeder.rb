# frozen_string_literal: true
require 'aws-sdk-sns'
require 'async'
require 'securerandom'
require 'json'

# id=arn:aws:sns:us-east-1:000000000000:user_seed

class DemoUserSeeder
  def initialize(count: 1000, queue_url:)
    @count = count
    @queue_url = queue_url
    @account_org_map = {}
    @existing_accounts = []
    @sns = Aws::SNS::Client.new(
      region: 'us-east-1',
      endpoint: 'http://eventstream:4566',
      access_key_id: 'fake',
      secret_access_key: 'fake'
    )
  end

  def seed!
    Async do |task|
      @count.times.each_slice(100) do |batch|
        task.async do
          batch.each do |i|
            payload = build_user_payload(i)
            send_payload(payload)
            print '.'
          end
        end
      end
    end.wait
    puts "\nDone seeding #{@count} jobs to SNS"
  end

  private

  def build_user_payload(index)
    account = nil
    organization = nil
    is_account_admin = false

    if reuse_existing_account?
      account = @existing_accounts.sample
      org_id = @account_org_map[account[:id]]
    else
      if create_child_account?
        parent = @existing_accounts.sample
        org_id = @account_org_map[parent[:id]]
        account = { id: SecureRandom.uuid, parent_account_id: parent[:id] }
        is_account_admin = false
      else
        organization = { id: SecureRandom.uuid }
        account = { id: SecureRandom.uuid }
        org_id = organization[:id]
        is_account_admin = true
      end

      @existing_accounts << account
      @account_org_map[account[:id]] = org_id
    end

    {
      type: "demo.user.create",
      index: index,
      user: {
        email: "user#{SecureRandom.hex(4)}@example.com",
        account_id: account[:id],
        is_admin: is_account_admin
      },
      account: account,
      organization: organization,
      org_id: org_id
    }
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
  DemoUserSeeder.new(count: ENV.fetch('USER_COUNT', 1_000).to_i, queue_url: queue_url).seed!
end
