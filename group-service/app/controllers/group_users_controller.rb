class GroupUsersController < ApplicationController
  before_action :set_group_user, only: %i[ show update destroy ]

  # GET /group_users
  def index
    filters = params.slice(*GroupUser.allowed_filters).permit!
    raise BadFilterError unless filters.present?
    results = GroupUser.where(*filters)
    auth = Instrumentation.trace("GroupUser.collection.authorize") { authorize_group_user_collection_read!(results) }
    return render json: auth, status: :accepted if auth

    results.load if results.respond_to?(:load)
    render json: results
  end

  # POST /group_users/search
  def search
    filters = params.permit(group_id: [], user_id: [], id: [])
    raise BadFilterError unless filters.present?

    results = GroupUser.where(*filters)
    auth = Instrumentation.trace("GroupUser.collection.authorize") { authorize_group_user_collection_read!(results) }
    return render json: auth, status: :accepted if auth

    results.load if results.respond_to?(:load)
    render json: results
  end

  # GET /group_users/1
  def show
    auth = authorize_group_user_collection_read!([@group_user])
    return render json: auth, status: :accepted if auth

    render json: @group_user
  end

  # POST /group_users
  def create
    @group_user = GroupUser.new(group_user_params)

    if @group_user.save
      render json: @group_user, status: :created, location: @group_user
    else
      render json: @group_user.errors, status: :unprocessable_entity
    end
  end

  # PATCH/PUT /group_users/1
  def update
    if @group_user.update(group_user_params)
      render json: @group_user
    else
      render json: @group_user.errors, status: :unprocessable_entity
    end
  end

  # DELETE /group_users/1
  def destroy
    @group_user.destroy!
  end

  private
    # Use callbacks to share common setup or constraints between actions.
    def set_group_user
      @group_user = GroupUser.find(params.expect(:id))
    end

    # Only allow a list of trusted parameters through.
    def group_user_params
      params.fetch(:group_user, {})
    end

  def authorize_group_user_collection_read!(group_users)
    user_id = request.headers["HTTP_PAD_USER_ID"]
    raise AuthorizationDenied, "no pad-user-id header sent" unless user_id
    return if user_id == "IAM_SYSTEM"

    group_ids = Array(group_users).map(&:group_id).map(&:to_s).uniq
    return if group_ids.empty?

    owning_groups = Group.where(id: group_ids).pluck(:id, :account_id)
    resolved_group_ids = owning_groups.map { |group_id, _account_id| group_id.to_s }
    missing_group_ids = group_ids - resolved_group_ids
    raise "group memberships reference missing groups: #{missing_group_ids.join(', ')}" if missing_group_ids.any?

    account_ids = owning_groups.map { |_group_id, account_id| account_id.to_s }.uniq

    if User.can_read_groups?(user_id, owning_groups)
      return
    end

    raise AuthorizationDenied, "no authorization for #{user_id} account.users.read #{account_ids}"
  end
end
