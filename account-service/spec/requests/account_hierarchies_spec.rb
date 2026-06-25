require 'rails_helper'

RSpec.describe "Account hierarchies", type: :request do
  class FakeAccountHierarchyCache
    attr_reader :writes, :sets

    def initialize
      @writes = {}
      @sets = Hash.new { |hash, key| hash[key] = [] }
    end

    def pipelined
      @commands = []
      yield self

      get_commands = @commands.select { |command| command.first == :get }
      get_commands.any? ? Array.new(get_commands.length) : []
    ensure
      @commands = nil
    end

    def get(key)
      @commands << [:get, key]
      nil
    end

    def set(key, value, ex:)
      @commands << [:set, key, value, ex]
      @writes[key] = { value: value, ttl: ex }
    end

    def sadd(key, value)
      @commands << [:sadd, key, value]
      @sets[key] << value
    end
  end

  let(:cache) { FakeAccountHierarchyCache.new }
  let(:organization_id) { SecureRandom.uuid }

  before do
    stub_const("ACCOUNT_CACHE", cache)
  end

  it "computes cold account hierarchy misses with one set-based CTE" do
    grandparent = Account.create!(name: "Grandparent")
    parent = Account.create!(name: "Parent", parent_account_id: grandparent.id)
    child_one = Account.create!(name: "Child One", parent_account_id: parent.id)
    child_two = Account.create!(name: "Child Two", parent_account_id: parent.id)
    seed_ids = [grandparent.id, parent.id, child_one.id, child_two.id].map(&:to_s)
    organization = Struct.new(:id).new(organization_id)

    allow(OrganizationAccount).to receive(:with_headers).and_yield
    allow(OrganizationAccount).to receive(:account_ids_for_organizations_by_account_ids).with(
      [child_one.id, child_two.id].map(&:to_s)
    ).and_return(
      child_one.id.to_s => { organization: organization, account_ids: seed_ids },
      child_two.id.to_s => { organization: organization, account_ids: seed_ids }
    )
    expect(ActiveRecord::Base.connection).to receive(:exec_query).with(
      kind_of(String),
      "AccountsWithParentsSetCTE",
      kind_of(Array)
    ).once.and_call_original

    post "/accounts_with_parents",
         params: { account_ids: [child_one.id, child_two.id] },
         headers: { "pad-user-id" => "IAM_SYSTEM" },
         as: :json

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.map { |hierarchy| hierarchy.map { |account| account.fetch("id") } }).to eq(
      [
        [grandparent.id, parent.id, child_one.id].map(&:to_s),
        [grandparent.id, parent.id, child_two.id].map(&:to_s)
      ]
    )
  end
end
