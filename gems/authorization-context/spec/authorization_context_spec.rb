# frozen_string_literal: true

RSpec.describe AuthorizationContext do
  describe "explicit contexts" do
    it "fails closed without an active context" do
      expect(described_class.current).to be_nil
      expect { described_class.current! }
        .to raise_error(AuthorizationContext::MissingContextError, /explicit authorization context/)
    end

    it "activates a requesting user and returns the block result" do
      result = described_class.as_requesting_user(user_id: " user-1 ") do
        context = described_class.current!

        expect(context).to be_requesting_user
        expect(context).not_to be_iam
        expect(context.user_id).to eq("user-1")
        expect(context.iam_identity).to be_nil
        expect(context.to_h).to eq(actor_id: "user-1")
        expect(context).to be_frozen
        :result
      end

      expect(result).to eq(:result)
      expect(described_class.current).to be_nil
    end

    it "accepts only the supported IAM identities" do
      expect(described_class.as_iam { described_class.current!.iam_identity }).to eq("IAM_SYSTEM")
      expect(described_class.as_iam(identity: "IAM_SYSTEM_AUTH") { described_class.current!.iam_identity })
        .to eq("IAM_SYSTEM_AUTH")
      expect { described_class.as_iam(identity: "service-1") {} }
        .to raise_error(AuthorizationContext::InvalidContextError, /unsupported IAM identity/)
      expect { described_class.as_requesting_user(user_id: "IAM_SYSTEM") {} }
        .to raise_error(AuthorizationContext::InvalidContextError, /not requesting users/)
    end

    it "rejects blank actors, missing blocks, and invalid captured values" do
      expect { described_class.as_requesting_user(user_id: "  ") {} }
        .to raise_error(AuthorizationContext::InvalidContextError, /user_id is required/)
      expect { described_class.as_iam(identity: nil) {} }
        .to raise_error(AuthorizationContext::InvalidContextError, /identity is required/)
      expect { described_class.as_requesting_user(user_id: "user-1") }
        .to raise_error(ArgumentError, /block required/)
      expect { described_class.with(Object.new) {} }
        .to raise_error(AuthorizationContext::InvalidContextError, /invalid captured context/)
    end

    it "restores nested context after an exception" do
      described_class.as_requesting_user(user_id: "outer") do
        expect do
          described_class.as_iam do
            expect(described_class.current!.actor_id).to eq("IAM_SYSTEM")
            raise "boom"
          end
        end.to raise_error("boom")

        expect(described_class.current!.actor_id).to eq("outer")
      end
    end

    it "restores context after a nonlocal return" do
      helper = Class.new do
        def self.call
          AuthorizationContext.as_requesting_user(user_id: "user-1") { return :returned }
        end
      end

      expect(helper.call).to eq(:returned)
      expect(described_class.current).to be_nil
    end

    it "captures and explicitly re-enters a context" do
      captured = described_class.as_requesting_user(user_id: "user-1") do
        described_class.capture
      end

      expect(described_class.with(captured) { described_class.current!.actor_id }).to eq("user-1")
      expect(described_class.current).to be_nil
    end

    it "temporarily removes an active context" do
      described_class.as_requesting_user(user_id: "user-1") do
        expect(described_class.without { described_class.current }).to be_nil
        expect(described_class.current!.actor_id).to eq("user-1")
      end
    end

    it "isolates concurrent thread contexts" do
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
  end

  describe "transport" do
    it "creates only the actor header" do
      headers = described_class.as_requesting_user(user_id: "user-1") do
        described_class.transport_headers
      end

      expect(headers).to eq("pad-user-id" => "user-1")
      expect(headers).to be_frozen
    end

    it "parses direct and Rack-style actor headers" do
      expect(described_class.from_headers("pad-user-id" => "user-1").actor_id).to eq("user-1")
      expect(described_class.from_headers("HTTP_PAD_USER_ID" => "IAM_SYSTEM_AUTH")).to be_iam
      expect { described_class.from_headers({}) }
        .to raise_error(AuthorizationContext::InvalidContextError, /actor_id is required/)
    end

    it "runs request work inside the parsed context and restores its predecessor" do
      described_class.as_requesting_user(user_id: "outer") do
        result = described_class.within_request("pad-user-id" => "inner") do
          described_class.current!.actor_id
        end

        expect(result).to eq("inner")
        expect(described_class.current!.actor_id).to eq("outer")
      end
    end
  end
end
