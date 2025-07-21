# frozen_string_literal: true

require 'aws-sdk-sqs'
require 'json'

class GrantsCreateQueueWorker
  POLL_INTERVAL = 1 # seconds
  MAX_MESSAGES = 10

  def initialize(queue_url: "http://eventstream:4566/000000000000/grants_create")
    @sqs = Aws::SQS::Client.new(
      region: 'us-east-1',
      endpoint: 'http://eventstream:4566',
      access_key_id: 'fake',
      secret_access_key: 'fake'
    )
    @queue_url = queue_url
  end

  def run
    puts "[grants-create-queue-worker] starting loop on #{@queue_url}"
    loop do
      resp = @sqs.receive_message(
        queue_url: @queue_url,
        max_number_of_messages: MAX_MESSAGES,
        wait_time_seconds: 1
      )

      if resp.messages.empty?
        sleep POLL_INTERVAL
        next
      end

      resp.messages.each do |msg|
        process(msg)
      end
    end
  end

  def process(msg)
    raw = JSON.parse(msg.body)
    body = false

    if raw["Type"] == "Notification" && raw["Message"]
      body = JSON.parse(raw["Message"])
    else
      body = raw
    end

    unless body["type"] == "demo.user.create"
      puts "[grants-create-queue-worker] unknown type: #{body["type"]}"
      return delete(msg)
    end

    user_data = body["user"]
    org_id = body["organization"]["id"]
    account_id = body["account"]["id"]
    is_admin = user_data["is_admin"]
    user_id = user_data["id"]

    CapabilityGrant.create!(user_id: user_id, permission: "organization.read", scope_type: "Organization", scope_id: org_id)
    CapabilityGrant.create!(user_id: user_id, permission: "organization.accounts.read", scope_type: "Organization", scope_id: org_id)

    if is_admin
      CapabilityGrant.create!(user_id: user_id, permission: "organization.accounts.create", scope_type: "Organization", scope_id: org_id)
      CapabilityGrant.create!(user_id: user_id, permission: "account.read", scope_type: "Account", scope_id: account_id)
      CapabilityGrant.create!(user_id: user_id, permission: "account.users.read", scope_type: "Account", scope_id: account_id)
      CapabilityGrant.create!(user_id: user_id, permission: "account.users.create", scope_type: "Account", scope_id: account_id)
    else
      CapabilityGrant.create!(user_id: user_id, permission: "account.read", scope_type: "Account", scope_id: account_id)
      CapabilityGrant.create!(user_id: user_id, permission: "account.users.read", scope_type: "Account", scope_id: account_id)
    end

    delete(msg)
  rescue => e
    puts "[grants-create-queue-worker] error processing message: #{e.class}: #{e.message}"
    puts e.backtrace.join("\n")
    # Optionally send to DLQ or log error
  end

  def delete(msg)
    @sqs.delete_message(
      queue_url: @queue_url,
      receipt_handle: msg.receipt_handle
    )
  end
end
