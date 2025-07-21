# frozen_string_literal: true

require 'aws-sdk-sqs'
require 'json'

class AccountCreateQueueWorker
  POLL_INTERVAL = 1 # seconds
  MAX_MESSAGES = 10

  def initialize(queue_url: "http://eventstream:4566/000000000000/account_create")
    @sqs = Aws::SQS::Client.new(
      region: 'us-east-1',
      endpoint: 'http://eventstream:4566',
      access_key_id: 'fake',
      secret_access_key: 'fake'
    )
    @queue_url = queue_url
  end

  def run
    puts "[account-create-queue-worker] starting loop on #{@queue_url}"
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
      puts "[account-create-queue-worker] unknown type: #{body["type"]}"
      return delete(msg)
    end

    account_data = body["account"]
    account_id = account_data["id"]
    parent_account_id = account_data["parent_account_id"]

    account = Account.find_by(id: account_id)
    if account
      puts "[account-create-queue-worker] already exists: #{account_id}"
    else
      account = Account.create!(
        id: account_id,
        parent_account_id: parent_account_id || nil
      )
      puts "[account-create-queue-worker] created: account_id=#{account.id}"
    end

    delete(msg)
  rescue => e
    puts "[account-create-queue-worker] error processing message: #{e.class}: #{e.message}"
    puts e.backtrace.join("\n")
    ap body
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

