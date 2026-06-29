class AccountsController < ApplicationController
  before_action :set_account, only: %i[ show update destroy ]

  # GET /accounts
  def index
    filters = params.slice(*Account.allowed_filters).permit!
    raise BadFilterError unless filters.present?
    results = Account.where(*filters)
    authorize_account_collection_read!(results)

    render json: results
  end

  # POST /accounts/search
  def search
    filters = params.permit(id: [])
    raise BadFilterError unless filters.present?
    results = Account.where(*filters)

    if msp_user_management_display_request?
      authorize_msp_account_display!(results)
      return render json: results.as_json(only: %i[id name])
    end

    authorize_account_collection_read!(results)

    render json: results
  end

  # GET /with_parent_accounts/1
  def account_with_parents
    account_id = params.permit(:account_id)[:account_id]
    results = fetch_account_with_parents(account_id)

    pad_user_id = request.headers['HTTP_PAD_USER_ID']
    if pad_user_id != "IAM_SYSTEM"
      raise "no authorization for #{pad_user_id} account.read #{account_id}" unless User.user_can(pad_user_id, "Account", "account.read",  account_id)
    end

    render json: results
  end

  # GET /with_parent_accounts
  def accounts_with_parents
    pad_user_id = request.headers['HTTP_PAD_USER_ID']
    raise "Access denied to non system user" unless pad_user_id == "IAM_SYSTEM"

    account_ids = params.permit(account_ids: [])[:account_ids]
    raise ActionController::BadRequest, "account_ids must be an array" unless account_ids.is_a?(Array)
    results = fetch_accounts_with_parents(account_ids)
    render json: results
  end

  # GET /accounts/1
  def show
    pad_user_id = request.headers['HTTP_PAD_USER_ID']
    raise "Must pass a pad-user-id header" unless pad_user_id
    if pad_user_id == "IAM_SYSTEM"
      OpenTelemetry::Trace.current_span.add_event("Skipping auth for system user")
    else
      OpenTelemetry::Trace.current_span.add_event("Checking auth for user #{pad_user_id}")
      raise "no authorization for #{pad_user_id} account.read #{@account.id}" unless User.user_can(pad_user_id, "Account", "account.read",  @account.id)
    end
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

  # Use callbacks to share common setup or constraints between actions.
  def set_account
    @account = Account.find(params.expect(:id))
  end

  # Only allow a list of trusted parameters through.
  def account_params
    params.permit(:parent_account_id)
  end

  def authorize_account_collection_read!(accounts)
    pad_user_id = request.headers['HTTP_PAD_USER_ID']
    raise "Must pass a pad-user-id header" unless pad_user_id

    if pad_user_id == "IAM_SYSTEM"
      OpenTelemetry::Trace.current_span.add_event("Skipping auth for system user")
      return
    end

    account_ids = accounts.respond_to?(:distinct) ? accounts.distinct.pluck(:id) : Array(accounts).map(&:id)
    account_ids = account_ids.map(&:to_s).uniq
    return if account_ids.empty?

    OpenTelemetry::Trace.current_span.add_event("Checking batched auth for user #{pad_user_id} account.read #{account_ids.size} accounts")
    raise "no authorization for #{pad_user_id} account.read #{account_ids}" unless User.user_can(pad_user_id, "Account", "account.read", account_ids)
  end

  def msp_user_management_display_request?
    request.headers['HTTP_PAD_MSP_ACCOUNT_ID'].present? && request.headers['HTTP_PAD_USER_ID'] != "IAM_SYSTEM"
  end

  def authorize_msp_account_display!(accounts)
    pad_user_id = request.headers['HTTP_PAD_USER_ID']
    msp_account_id = request.headers['HTTP_PAD_MSP_ACCOUNT_ID']
    raise "Must pass a pad-user-id header" unless pad_user_id

    account_ids = accounts.respond_to?(:distinct) ? accounts.distinct.pluck(:id) : Array(accounts).map(&:id)
    account_ids = account_ids.map(&:to_s).uniq
    return if account_ids.empty?

    OpenTelemetry::Trace.current_span.add_event("Checking MSP reflected account display auth for user #{pad_user_id} #{account_ids.size} accounts")
    allowed = User.user_can(
      pad_user_id,
      "Account",
      "account.users.read",
      account_ids,
      "pad-msp-account-id" => msp_account_id
    )
    raise "no MSP reflected authorization for #{pad_user_id} account display #{account_ids}" unless allowed
  end

  def fetch_account_with_parents(account_id)
    fetch_accounts_with_parents([account_id]).first
  end

  def fetch_accounts_with_parents(account_ids)
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

    if misses.any?
      OpenTelemetry::Trace.current_span.add_event("Fetching #{misses.size} account_with_parents misses")
      organization_payloads = {}
      OrganizationAccount.with_headers('pad-user-id' => 'IAM_SYSTEM') do
        organization_payloads = OrganizationAccount.account_ids_for_organizations_by_account_ids(misses)
      end

      computed = compute_accounts_with_parents(misses, organization_payloads)
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
      account_ancestry(root_id, organization_id, id, parent_account_id, name, level) AS (
        SELECT roots.root_id, roots.organization_id, accounts.id, accounts.parent_account_id, accounts.name, 0 AS level
        FROM roots
        INNER JOIN accounts ON accounts.id = roots.root_id

        UNION ALL

        SELECT account_ancestry.root_id, account_ancestry.organization_id, parents.id, parents.parent_account_id, parents.name, account_ancestry.level + 1
        FROM account_ancestry
        INNER JOIN roots ON roots.root_id = account_ancestry.root_id
        INNER JOIN accounts parents ON parents.id = account_ancestry.parent_account_id
        WHERE parents.id = ANY(roots.seed_ids)
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
