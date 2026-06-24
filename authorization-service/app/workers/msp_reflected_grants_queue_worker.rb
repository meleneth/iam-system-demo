# frozen_string_literal: true

require "aws-sdk-sqs"
require "json"

class MspReflectedGrantsQueueWorker
  POLL_INTERVAL = 1
  MAX_MESSAGES = 10

  def initialize(queue_url: "http://eventstream:4566/000000000000/msp_reflected_grants")
    @sqs = Aws::SQS::Client.new(
      region: "us-east-1",
      endpoint: "http://eventstream:4566",
      access_key_id: "fake",
      secret_access_key: "fake"
    )
    @queue_url = queue_url
  end

  def run
    puts "[msp-reflected-grants-worker] starting loop on #{@queue_url}"
    loop do
      resp = @sqs.receive_message(queue_url: @queue_url, max_number_of_messages: MAX_MESSAGES, wait_time_seconds: 1)
      if resp.messages.empty?
        sleep POLL_INTERVAL
        next
      end

      resp.messages.each { |msg| process(msg) }
    end
  end

  def process(msg)
    body = JSON.parse(msg.body)
    unless body["type"] == "msp_reflected_user_grants.load"
      puts "[msp-reflected-grants-worker] unknown type: #{body["type"]}"
      return delete(msg)
    end

    Authorization::MspReflectedUserGrants.new.load!(
      user_id: body.fetch("user_id"),
      msp_account_id: body.fetch("msp_account_id")
    )
    delete(msg)
  rescue => e
    puts "[msp-reflected-grants-worker] error processing message: #{e.class}: #{e.message}"
    puts e.backtrace.join("\n")
  end

  def delete(msg)
    @sqs.delete_message(queue_url: @queue_url, receipt_handle: msg.receipt_handle)
  end
end
