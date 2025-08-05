require 'rails_helper'
require 'securerandom'

RSpec.describe Authorization::AccountGrantChecker do
  let(:hierarchy) { build(:account_hierarchy) }
  let(:hierarchy_grandparent) { hierarchy[0] }
  let(:other_hierarchy) { build(:account_hierarchy) }
  let(:other_hierarchy_grandparent) { other_hierarchy[0] }
  let(:other_hierarchy_parent) { other_hierarchy[1] }
  let(:other_hierarchy_child) { other_hierarchy[2] }
  let(:user_id) { SecureRandom.uuid }
  let(:permission) { "account.read" }

  let(:fake_redis) do
  instance_double(Redis,
      get: nil,
      set: nil,
      del: nil,
      exists?: false,
      sadd: nil,
      smembers: [],
      expire: nil,
      pipelined: nil
    )
  end

  let(:subject) { Authorization::AccountGrantChecker.new(user_id: user_id, permission: permission, redis: fake_redis) }

  before :each do
    allow_any_instance_of(Authorization::AccountGrantChecker).to receive(:cached_user_grants)
      .and_return("some_key")
  end

  it "can instantiate" do
    expect(subject).to be_truthy
  end

  describe "#authorized_for_all?" do
    it "works for a single hierarchy" do
      expect(subject).to receive(:batch_check)
        .with([hierarchy_grandparent.id])
        .and_return({hierarchy_grandparent.id =>  true})
      expect(subject.authorized_for_all?([hierarchy])).to be_truthy
    end

    it "works for a multiple hierarchies" do
      expect(subject).to receive(:batch_check)
        .with([hierarchy_grandparent.id, other_hierarchy_grandparent.id])
        .and_return({hierarchy_grandparent.id =>  true, other_hierarchy_grandparent.id => true})
      expect(subject.authorized_for_all?([hierarchy, other_hierarchy])).to be_truthy
    end

    it "returns false if any hierarchy does not have the required permission" do
      expect(subject).to receive(:batch_check)
        .with([hierarchy_grandparent.id, other_hierarchy_grandparent.id])
        .and_return({hierarchy_grandparent.id =>  true, other_hierarchy_grandparent.id => false})

      expect(subject).to receive(:batch_check)
        .with([other_hierarchy_parent.id])
        .and_return({other_hierarchy_parent.id => false})

      expect(subject).to receive(:batch_check)
        .with([other_hierarchy_child.id])
        .and_return({other_hierarchy_child.id => false})

      expect(subject.authorized_for_all?([hierarchy, other_hierarchy])).to be_falsey
    end
  end
end
