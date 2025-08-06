# frozen_string_literal: true

require 'spec_helper'
require 'mel/multi_fetch_cache'

RSpec.describe Mel::MultiFetchCache do
  let(:redis) { instance_double("Redis") }
  let(:key_proc) { ->(k) { "key:#{k}" } }
  let(:tracking_key_proc) { ->(k) { "track:#{k}" } }

  it "returns all hits without calling block" do
    keys = %w[a b]

    expect(redis).to receive(:pipelined).and_yield.and_return(["1", "2"])

    expect(redis).to receive(:get).with("key:a").and_return(1)
    expect(redis).to receive(:get).with("key:b").and_return(2)

    result = Mel::MultiFetchCache.fetch_many(
      keys: keys,
      ttl: 300,
      cache: redis,
      key_proc: key_proc
    ) do |_missing|
      raise "Block should not be called"
    end

    expect(result).to eq("a" => 1, "b" => 2)
  end

  it "calls block for misses and writes back with setex" do
    keys = %w[x y]
    redis_keys = keys.map(&key_proc)

    expect(redis).to receive(:pipelined).and_yield.and_return([nil, nil]).twice

    expect(redis).to receive(:get).with("key:x")
    expect(redis).to receive(:get).with("key:y")

    expect(redis).to receive(:setex).with("key:x", 300, "10")
    expect(redis).to receive(:setex).with("key:y", 300, "20")

    result = Mel::MultiFetchCache.fetch_many(
      keys: keys,
      ttl: 300,
      cache: redis,
      key_proc: key_proc
    ) do |missing|
      { "x" => 10, "y" => 20 }
    end

    expect(result).to eq("x" => 10, "y" => 20)
  end

  it "writes to tracking tag if configured" do
    keys = %w[a b]
    redis_keys = keys.map(&key_proc)

    expect(redis).to receive(:pipelined).twice.and_yield.and_return([nil, nil])

    expect(redis).to receive(:get).with("key:a").and_return(nil)
    expect(redis).to receive(:get).with("key:b").and_return(nil)

    expect(redis).to receive(:setex).with("key:a", 300, 100.to_json)
    expect(redis).to receive(:setex).with("key:b", 300, 200.to_json)

    expect(redis).to receive(:sadd).with("tagset", "track:a")
    expect(redis).to receive(:sadd).with("tagset", "track:b")

    result = Mel::MultiFetchCache.fetch_many(
      keys: keys,
      ttl: 300,
      tag: "tagset",
      cache: redis,
      key_proc: key_proc,
      tracking_key_proc: tracking_key_proc
    ) do |_misses|
      { "a" => 100, "b" => 200 }
    end

    expect(result).to eq("a" => 100, "b" => 200)
  end

  it "yields the cacher instance if block arity is 2" do
    expect(redis).to receive(:pipelined).twice.and_yield.and_return([nil])

    expect(redis).to receive(:get).with("key:z")
    expect(redis).to receive(:setex).with("key:z", 300, "hello".to_json)

    called = false

    Mel::MultiFetchCache.fetch_many(
      keys: ["z"],
      ttl: 300,
      cache: redis,
      key_proc: key_proc
    ) do |misses, cacher|
      expect(misses).to eq(["z"])
      expect(cacher).to be_a(Mel::MultiFetchCache)
      called = true
      { "z" => "hello" }
    end

    expect(called).to be true
  end

  it "returns nil for keys not returned by block" do
    expect(redis).to receive(:pipelined).twice.and_yield.and_return([nil, nil])

    expect(redis).to receive(:get).with("key:a")
    expect(redis).to receive(:get).with("key:b")

    expect(redis).to receive(:setex).with("key:a", 300, "filled".to_json)

    result = Mel::MultiFetchCache.fetch_many(
      keys: %w[a b],
      ttl: 300,
      cache: redis,
      key_proc: key_proc
    ) do |_misses|
      { "a" => "filled" }
    end

    expect(result).to eq("a" => "filled", "b" => nil)
  end

  it "raises error if block doesn't return a hash" do
    expect(redis).to receive(:pipelined).once.and_yield.and_return([nil])
    expect(redis).to receive(:get).with("key:oops")

    expect {
      Mel::MultiFetchCache.fetch_many(
        keys: ["oops"],
        ttl: 300,
        cache: redis,
        key_proc: key_proc
      ) do |_misses|
        "not a hash"
      end
    }.to raise_error(ArgumentError, /Block must return a hash/)
  end
end
