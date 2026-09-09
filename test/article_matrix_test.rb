require "minitest/autorun"
require "json"
require_relative "../scripts/collect_article_evidence"

class ArticleMatrixTest < Minitest::Test
  def setup
    @cases = JSON.parse(File.read(File.expand_path("../benchmarks/article_matrix.json", __dir__))).fetch("cases").to_h { |item| [item.fetch("id"), item] }
  end

  def test_retrieval_pairs_change_only_retrieval_mode
    %w[deep wide].each do |shape|
      serial = @cases.fetch("retrieval-#{shape}-serial").reject { |key, _| %w[id retrieval].include?(key) }
      batched = @cases.fetch("retrieval-#{shape}-batched").reject { |key, _| %w[id retrieval].include?(key) }
      assert_equal serial, batched
    end
  end

  def test_authorization_pair_changes_only_authorization_mode
    capability = @cases.fetch("retrieval-wide-batched").reject { |key, _| %w[id auth].include?(key) }
    can = @cases.fetch("auth-wide-can").reject { |key, _| %w[id auth].include?(key) }
    assert_equal capability, can
  end

  def test_profile_environment_explicitly_overrides_cache_and_dataset_flags
    config = ArticleCollection.case_environment(@cases.fetch("graphql-cache-b200"), "/output", "/manifest", 3)
    assert_equal "200", config.fetch("IAM_DEMO_BATCH_SIZE")
    assert_equal "true", config.fetch("GLOBAL_IAM_DEMO_USE_REDIS")
    assert_equal "1", config.fetch("REDIS_CACHE_DB")
    assert_equal "1", config.fetch("ARCHIVE_TRACES")
    assert_equal "0", config.fetch("INCLUDE_MSP_100K")
    assert_equal "0", config.fetch("INCLUDE_MSP_50K")
    assert_equal "1", config.fetch("INCLUDE_MSP_10K")
  end
end
