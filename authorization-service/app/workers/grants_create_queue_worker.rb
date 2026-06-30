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
    body = AwsMessage.unwrap(msg)

    unless body["type"] == "demo.user.create"
      puts "[grants-create-queue-worker] unknown type: #{body["type"]}"
      return delete(msg)
    end

    rows = grant_rows(body)
    validate_grant_rows!(rows, body)
    result = CapabilityGrant.insert_all(
      rows,
      unique_by: :index_capability_grants_on_user_perm_scope,
      returning: %w[id]
    )
    inserted_count = result.rows.length
    if inserted_count != rows.length
      puts "[grants-create-queue-worker] duplicate native grant projection: inserted=#{inserted_count} expected=#{rows.length} index=#{body["index"]} fixture=#{body["fixture"]} user_id=#{body.dig("user", "id")}"
    end

    delete(msg)
  rescue => e
    puts "[grants-create-queue-worker] error processing message: #{e.class}: #{e.message}"
    puts e.backtrace.join("\n")
    puts JSON.pretty_generate(body) if defined?(body) && body
    # Optionally send to DLQ or log error
  end

  def delete(msg)
    @sqs.delete_message(
      queue_url: @queue_url,
      receipt_handle: msg.receipt_handle
    )
  end

  private

  def grant_rows(body)
    user_data = body.fetch("user")
    org_id = body.fetch("organization").fetch("id")
    account_id = body.fetch("account").fetch("id")
    is_admin = user_data.fetch("is_admin")
    user_id = user_data.fetch("id")
    groups = Array(body["groups"])
    timestamp = Time.current

    raw_grants = []
    add_grant(raw_grants, user_id, "organization.read", "Organization", org_id, timestamp)
    add_grant(raw_grants, user_id, "organization.read.accounts", "Organization", org_id, timestamp)
    add_grant(raw_grants, user_id, "account.read", "Account", account_id, timestamp)
    add_grant(raw_grants, user_id, "account.users.read", "Account", account_id, timestamp)

    if is_admin
      add_grant(raw_grants, user_id, "organization.accounts.create", "Organization", org_id, timestamp)
      add_grant(raw_grants, user_id, "account.users.create", "Account", account_id, timestamp)
      add_grant(raw_grants, user_id, "group.create", "Account", account_id, timestamp)
      groups.each do |group|
        add_grant(raw_grants, user_id, "group.modify", "Group", group.fetch("id"), timestamp)
      end
    end

    groups.each do |group|
      add_grant(raw_grants, user_id, "group.read", "Group", group.fetch("id"), timestamp)
    end

    grants = raw_grants.uniq { |grant| [grant[:user_id], grant[:permission], grant[:scope_type], grant[:scope_id]] }
    if grants.length != raw_grants.length
      puts "[grants-create-queue-worker] duplicate grants inside one event: raw=#{raw_grants.length} deduped=#{grants.length} index=#{body["index"]} fixture=#{body["fixture"]} user_id=#{user_id}"
    end

    grants
  end

  def validate_grant_rows!(rows, body)
    invalid_rows = rows.select do |row|
      row[:user_id].blank? || row[:permission].blank? || row[:scope_type].blank? || row[:scope_id].blank?
    end
    return if invalid_rows.empty?

    raise ArgumentError,
          "invalid native grant projection: invalid_rows=#{invalid_rows.length} index=#{body["index"]} fixture=#{body["fixture"]} user_id=#{body.dig("user", "id")}"
  end

  def add_grant(grants, user_id, permission, scope_type, scope_id, timestamp)
    grants << {
      user_id: user_id,
      permission: permission,
      scope_type: scope_type,
      scope_id: scope_id,
      created_at: timestamp,
      updated_at: timestamp
    }
  end
end

class AwsMessage
  def self.unwrap(sqs_message)
    outer = JSON.parse(sqs_message.body)
    if outer.is_a?(Hash) && outer['Type'] == 'Notification' && outer['Message']
      JSON.parse(outer['Message'])
    else
      outer
    end
  end
end
