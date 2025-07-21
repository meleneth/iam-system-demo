# frozen_string_literal: true

require 'aws-sdk-sqs'
require 'json'

class UserCreateQueueWorker
  POLL_INTERVAL = 1 # seconds
  MAX_MESSAGES = 10

  def initialize(queue_url: "http://eventstream:4566/000000000000/user_create")
    @sqs = Aws::SQS::Client.new(
      region: 'us-east-1',
      endpoint: 'http://eventstream:4566',
      access_key_id: 'fake',
      secret_access_key: 'fake'
    )
    @queue_url = queue_url
  end

  def run
    puts "[user-queue-worker] starting loop on #{@queue_url}"
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
      puts "[user-queue-worker] unknown type: #{body["type"]}"
      return delete(msg)
    end

    user_data = body["user"]
    email     = user_data["email"]
    account_id = user_data["account_id"]
    user_id = user_data["id"]

    user = User.find_by(id: user_id)
    if user
      puts "[user-queue-worker] already exists: #{email}"
    else
      user = User.create!(
        id: user_id,
        email: email,
        account_id: account_id
      )
      puts "[user-queue-worker] created: #{email} (user_id=#{user.id})"
    end

    delete(msg)
  rescue => e
    puts "[user-queue-worker] error processing message: #{e.class}: #{e.message}"
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

