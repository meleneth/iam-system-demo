# frozen_string_literal: true

require 'aws-sdk-sqs'
require 'json'

class OrganizationCreateQueueWorker
  POLL_INTERVAL = 1 # seconds
  MAX_MESSAGES = 10

  def initialize(queue_url: "http://eventstream:4566/000000000000/organization_create")
    @sqs = Aws::SQS::Client.new(
      region: 'us-east-1',
      endpoint: 'http://eventstream:4566',
      access_key_id: 'fake',
      secret_access_key: 'fake'
    )
    @queue_url = queue_url
  end

  def run
    puts "[organization-create-queue-worker] starting loop on #{@queue_url}"
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
      puts "[organization-create-queue-worker] unknown type: #{body["type"]}"
      return delete(msg)
    end

    organization_data = body["organization"]
    organization_id = organization_data["id"]
    account_id = body["account"]["id"]

    organization = Organization.find_by(id: organization_id)
    if organization
      puts "[organization-create-queue-worker] already exists: #{organization_id}"
    else
      organization = Organization.create!(id: organization_id)
      puts "[organization-create-queue-worker] created: organization_id=#{organization.id}"
    end

    organization_account = OrganizationAccount.find_by(organization_id: organization_id, account_id: account_id)
    if organization_account
      puts "[organization-create-queue-worker] OrgAccount already exists: #{organization_id} -> #{account_id}"
    else
      organization_account = OrganizationAccount.create!(
        organization_id: organization_id,
        account_id: account_id
      )
      puts "[organization-create-queue-worker] created: org_account_id=#{organization_account.id}"
    end

    if (msp_account_id = body["msp_managed_by_account_id"]).present?
      result = MspManagedAccount.insert_all(
        [
          {
            msp_account_id: msp_account_id,
            managed_account_id: account_id,
            created_at: Time.current,
            updated_at: Time.current
          }
        ],
        unique_by: :idx_msp_managed_accounts_unique_pair,
        returning: %w[id]
      )
      if result.rows.empty?
        puts "[organization-create-queue-worker] duplicate MSP mapping projection: index=#{body["index"]} fixture=#{body["fixture"]} msp_account_id=#{msp_account_id} managed_account_id=#{account_id}"
      end
      puts "[organization-create-queue-worker] MSP mapping: #{msp_account_id} -> #{account_id}"
    end

    delete(msg)
  rescue => e
    puts "[organization-create-queue-worker] error processing message: #{e.class}: #{e.message}"
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
