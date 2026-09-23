# frozen_string_literal: true

RSpec.describe AuthorizedResource::Operation do
  let(:resource_class) { class_double(AuthorizedResource::Base, name: "RemoteWidget", site: nil) }

  it "requires context before running an operation" do
    expect(AuthorizedResource::Instrumentation).not_to receive(:trace)

    expect { described_class.within(resource_class, "find") { :unreachable } }
      .to raise_error(AuthorizationContext::MissingContextError)
  end

  it "traces the outer operation and suppresses a nested operation for the same resource" do
    span = instance_double(OpenTelemetry::Trace::Span)
    expect(AuthorizedResource::Instrumentation).to receive(:trace)
      .with(resource_class, "find").once.and_yield(span)

    result = AuthorizationContext.as_requesting_user(user_id: "actor-1") do
      described_class.within(resource_class, "find") do |outer_span, outermost|
        expect([outer_span, outermost]).to eq([span, true])
        expect(described_class.current).to eq(resource_class)

        described_class.within(resource_class, "connection_get") do |inner_span, inner_outermost|
          expect([inner_span, inner_outermost]).to eq([nil, false])
          :result
        end
      end
    end

    expect(result).to eq(:result)
    expect(described_class.current).to be_nil
  end

  it "restores operation state after an exception" do
    allow(AuthorizedResource::Instrumentation).to receive(:trace).and_yield(nil)

    expect do
      AuthorizationContext.as_iam do
        described_class.within(resource_class, "find") { raise "boom" }
      end
    end.to raise_error("boom")
    expect(described_class.current).to be_nil
  end
end
