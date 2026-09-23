# frozen_string_literal: true

require_relative "../rails_helper"

RSpec.describe AuthorizationContext do
  it "has no default and rejects invalid actors" do
    expect { described_class.current! }.to raise_error(AuthorizationContext::MissingContextError)
    expect { described_class.as_requesting_user(user_id: "") {} }.to raise_error(AuthorizationContext::InvalidContextError)
    expect { described_class.as_requesting_user(user_id: "IAM_SYSTEM") {} }.to raise_error(AuthorizationContext::InvalidContextError)
    expect { described_class.as_iam(identity: "actor-1") {} }.to raise_error(AuthorizationContext::InvalidContextError)

    invalid = described_class::Context.new(actor_id: nil)
    expect { described_class.with(invalid) {} }.to raise_error(AuthorizationContext::InvalidContextError)
  end

  it "returns block values and restores nested actors after exceptions" do
    result = described_class.as_requesting_user(user_id: "actor-1") do
      expect(described_class.current!.to_h).to eq(actor_id: "actor-1")
      expect(described_class.current!).to be_requesting_user
      expect do
        described_class.as_iam do
          expect(described_class.current!.actor_id).to eq("IAM_SYSTEM")
          expect(described_class.current!).to be_iam
          raise "boom"
        end
      end.to raise_error("boom")
      expect(described_class.current!.actor_id).to eq("actor-1")
      :result
    end

    expect(result).to eq(:result)
    expect { described_class.current! }.to raise_error(AuthorizationContext::MissingContextError)
  end

  it "restores state after a nonlocal return" do
    helper = Class.new do
      def self.call
        AuthorizationContext.as_requesting_user(user_id: "actor-1") { return :returned }
      end
    end
    expect(helper.call).to eq(:returned)
    expect { described_class.current! }.to raise_error(AuthorizationContext::MissingContextError)
  end

  it "does not leak contexts between concurrent threads" do
    ready = Queue.new
    release = Queue.new
    observed = Queue.new
    threads = %w[user-a user-b].map do |user_id|
      Thread.new do
        described_class.as_requesting_user(user_id: user_id) do
          ready << true
          release.pop
          observed << described_class.current!.actor_id
        end
      end
    end
    2.times { ready.pop }
    2.times { release << true }
    threads.each(&:join)
    expect(2.times.map { observed.pop }.sort).to eq(%w[user-a user-b])
  end

  it "derives the actor solely from pad-user-id" do
    expect(described_class.from_headers("pad-user-id" => "actor-1").to_h).to eq(actor_id: "actor-1")
    expect(described_class.from_headers("pad-user-id" => "IAM_SYSTEM")).to be_iam
    expect(described_class.from_headers("pad-user-id" => "IAM_SYSTEM_AUTH").iam_identity).to eq("IAM_SYSTEM_AUTH")
  end
end
