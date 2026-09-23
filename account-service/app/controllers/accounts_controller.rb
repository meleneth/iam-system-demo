class AccountsController < ApplicationController
  MAX_ACCOUNT_HIERARCHY_DEPTH = 100

  before_action :set_account, only: %i[ show update destroy ]

  # GET /accounts
  def index
    filters = params.slice(*Account.allowed_filters).permit!
    raise BadFilterError unless filters.present?
    results = Account.where(*filters)
    results.load if results.respond_to?(:load)
    render json: results
  end

  # POST /accounts/search
  def search
    filters = params.permit(id: [])
    raise BadFilterError unless filters.present?
    results = Account.where(*filters)
    results.load if results.respond_to?(:load)
    render json: results
  end

  # GET /with_parent_accounts/1
  def account_with_parents
    account_id = params.permit(:account_id)[:account_id]
    authorize_hierarchy_records!([account_id], [])
    results = fetch_account_with_parents(account_id)
    authorize_hierarchy_records!([], [results])
    results.load if results.respond_to?(:load)
    render json: results
  end

  # GET /with_parent_accounts
  def accounts_with_parents
    account_ids = params.permit(account_ids: [])[:account_ids]
    raise ActionController::BadRequest, "account_ids must be an array" unless account_ids.is_a?(Array)
    authorize_hierarchy_records!(account_ids, [])
    results = fetch_accounts_with_parents(account_ids)
    authorize_hierarchy_records!([], results)
    results.load if results.respond_to?(:load)
    render json: results
  end

  # GET /accounts/1
  def show
    render json: @account
  end

  # POST /accounts
  def create
    @account = Account.new(account_params)

    if @account.save
      render json: @account, status: :created, location: @account
    else
      render json: @account.errors, status: :unprocessable_entity
    end
  end

  # PATCH/PUT /accounts/1
  def update
    if @account.update(account_params)
      render json: @account
    else
      render json: @account.errors, status: :unprocessable_entity
    end
  end

  # DELETE /accounts/1
  def destroy
    @account.destroy!
  end

  private

  def authorize_hierarchy_records!(requested_ids, hierarchies)
    returned_ids = Array(hierarchies).flatten.compact.map { |row| row.fetch("id").to_s }
    records = (Array(requested_ids).map(&:to_s) + returned_ids).uniq.map { |id| Account.new(id: id) }
    Account.authorized_read("hierarchy", records: records) { hierarchies }
  end

  # Use callbacks to share common setup or constraints between actions.
  def set_account
    @account = Account.find(params.expect(:id))
  end

  # Only allow a list of trusted parameters through.
  def account_params
    params.permit(:parent_account_id)
  end

  def fetch_account_with_parents(account_id)
    fetch_accounts_with_parents([account_id]).first
  end

  def fetch_accounts_with_parents(account_ids)
    AuthorizationContext.current!
    ids = Array(account_ids).map(&:to_s)
    cache_keys = ids.map { |id| account_with_parents_cache_key(id) }

    cached_values = ACCOUNT_CACHE.pipelined do |pipe|
      cache_keys.each { |cache_key| pipe.get(cache_key) }
    end

    by_id = {}
    misses = []

    if cache_disabled?
      OpenTelemetry::Trace.current_span.add_event("Redis cache disabled; treating #{ids.size} account_with_parents entries as misses")
    end

    ids.each_with_index do |id, index|
      cached = cached_values[index]
      if cached
        OpenTelemetry::Trace.current_span.add_event("Fetching cached account_with_parents SUCCESS!")
        by_id[id] = JSON.parse(cached)
      else
        misses << id
      end
    end
    IamDemo::CacheMetrics.record(
      cache: "account_with_parents",
      outcome: "hit",
      count: ids.size - misses.size,
      redis_enabled: !cache_disabled?
    )
    IamDemo::CacheMetrics.record(
      cache: "account_with_parents",
      outcome: "miss",
      count: misses.size,
      redis_enabled: !cache_disabled?
    )

    if misses.any?
      OpenTelemetry::Trace.current_span.add_event("Fetching #{misses.size} account_with_parents misses")
      organization_payloads = {}
      existing_misses = []
      AuthorizationContext.as_iam do
        existing_misses = Account.where(id: misses).pluck(:id).map(&:to_s)
        organization_payloads = OrganizationAccount.account_ids_for_organizations_by_account_ids(existing_misses) if existing_misses.any?
      end
      (misses - existing_misses).each { |id| by_id[id] = [] }

      computed = compute_accounts_with_parents(existing_misses, organization_payloads)
      computed.each { |id, (results, _org_key_set)| by_id[id] = results }

      unless cache_disabled?
        ACCOUNT_CACHE.pipelined do |pipe|
          computed.each do |id, (results, org_key_set)|
            cache_key = account_with_parents_cache_key(id)
            pipe.set(cache_key, results.to_json, ex: 300)
            pipe.sadd(org_key_set, cache_key) if org_key_set.present?
          end
        end
      else
        OpenTelemetry::Trace.current_span.add_event("Redis cache disabled; skipped writing #{computed.size} account_with_parents entries")
      end
    end

    ids.map { |id| by_id[id] }
  end

  def cache_disabled?
    ACCOUNT_CACHE.respond_to?(:redis_enabled?) && !ACCOUNT_CACHE.redis_enabled?
  end

  def account_with_parents_cache_key(account_id)
    "account_with_parents:#{account_id}"
  end

  def compute_accounts_with_parents(account_ids, organization_payloads)
    AuthorizationContext.current!
    OpenTelemetry::Trace.current_span.add_event("Fetching account_with_parents misses with set-based CTE")

    ids = Array(account_ids).map(&:to_s)
    return {} if ids.empty?

    uuid_type = ActiveRecord::Type.lookup(:uuid)
    uuid_array_type = ActiveRecord::Type.lookup(:uuid, array: true)

    binds = []
    placeholders = []

    ids.each_with_index do |id, index|
      response = organization_payloads.fetch(id)
      organization = response.fetch(:organization)
      seed_ids = Array(response.fetch(:account_ids)).map(&:to_s)

      root_index = (index * 3) + 1
      organization_index = root_index + 1
      seed_ids_index = root_index + 2

      placeholders << "($#{root_index}::uuid, $#{organization_index}::uuid, $#{seed_ids_index}::uuid[])"
      binds << ActiveRecord::Relation::QueryAttribute.new("root_account_id_#{index}", id, uuid_type)
      binds << ActiveRecord::Relation::QueryAttribute.new("organization_id_#{index}", organization.id, uuid_type)
      binds << ActiveRecord::Relation::QueryAttribute.new("seed_ids_#{index}", seed_ids, uuid_array_type)
    end

    sql = <<~SQL
      WITH RECURSIVE roots(root_id, organization_id, seed_ids) AS (
        VALUES #{placeholders.join(",\n               ")}
      ),
      account_ancestry(root_id, organization_id, id, parent_account_id, name, level, path) AS (
        SELECT roots.root_id, roots.organization_id, accounts.id, accounts.parent_account_id, accounts.name, 0 AS level, ARRAY[accounts.id]::uuid[] AS path
        FROM roots
        INNER JOIN accounts ON accounts.id = roots.root_id

        UNION ALL

        SELECT account_ancestry.root_id, account_ancestry.organization_id, parents.id, parents.parent_account_id, parents.name, account_ancestry.level + 1, account_ancestry.path || parents.id
        FROM account_ancestry
        INNER JOIN roots ON roots.root_id = account_ancestry.root_id
        INNER JOIN accounts parents ON parents.id = account_ancestry.parent_account_id
        WHERE parents.id = ANY(roots.seed_ids)
          AND NOT parents.id = ANY(account_ancestry.path)
          AND account_ancestry.level + 1 < #{MAX_ACCOUNT_HIERARCHY_DEPTH}
      )
      SELECT root_id, organization_id, id, parent_account_id, name, level
      FROM account_ancestry
      ORDER BY root_id, level DESC
    SQL

    rows = ActiveRecord::Base.connection.exec_query(sql, "AccountsWithParentsSetCTE", binds).to_a
    rows_by_root = rows.group_by { |row| row.fetch("root_id").to_s }

    ids.to_h do |id|
      response = organization_payloads.fetch(id)
      organization = response.fetch(:organization)
      org_key_set = "org_cachekeys:#{organization.id}"
      results = Array(rows_by_root[id]).map { |row| row.except("root_id", "organization_id") }

      [id, [results, org_key_set]]
    end
  end
end
