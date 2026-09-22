# frozen_string_literal: true

require_relative "../rails_helper"

RSpec.describe "protected ActiveRecord retrievals" do
  it "rejects a deferred relation before SQL executes without context" do
    relation = AuthorizationContext.as_requesting_user(user_id: SecureRandom.uuid) { Account.where(id: SecureRandom.uuid) }
    expect { relation.to_a }.to raise_error(AuthorizationContext::MissingContextError)
    expect { Account.unscoped.exists?(id: SecureRandom.uuid) }.to raise_error(AuthorizationContext::MissingContextError)
  end

  it "rejects Active Record async loading unless context propagation is explicit" do
    expect do
      AuthorizationContext.as_requesting_user(user_id: SecureRandom.uuid) { Account.all.load_async }
    end.to raise_error(AuthorizationContext::InvalidContextError, /context propagation/)
  end

  it "rejects a protected cache read before consulting the cache" do
    cache = instance_double(IamDemo::NullRedisCache)
    stub_const("ACCOUNT_CACHE", cache)
    expect(cache).not_to receive(:pipelined)

    expect do
      AccountsController.new.send(:fetch_accounts_with_parents, [SecureRandom.uuid])
    end.to raise_error(AuthorizationContext::MissingContextError)
  end

  it "permits retrieval within either explicit authority" do
    expect(AuthorizationContext.as_requesting_user(user_id: SecureRandom.uuid) { Account.none.to_a }).to eq([])
    expect(AuthorizationContext.as_iam { Account.none.to_a }).to eq([])
  end
end
