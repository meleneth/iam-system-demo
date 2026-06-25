class GroupUsersController < ApplicationController
  before_action :set_group_user, only: %i[ show update destroy ]

  # GET /group_users
  def index
    filters = params.slice(*GroupUser.allowed_filters).permit!
    raise BadFilterError unless filters.present?
    results = GroupUser.where(*filters)
    auth = authorize_group_user_collection_read!(results)
    return render json: auth, status: :accepted if auth

    render json: results
  end

  # POST /group_users/search
  def search
    filters = params.permit(group_id: [], user_id: [], id: [])
    raise BadFilterError unless filters.present?

    results = GroupUser.where(*filters)
    auth = authorize_group_user_collection_read!(results)
    return render json: auth, status: :accepted if auth

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
    raise "no pad-user-id header sent" unless user_id
    return if user_id == "IAM_SYSTEM"

    group_ids = Array(group_users).map(&:group_id).map(&:to_s).uniq
    return if group_ids.empty?

    account_ids = Group.where(id: group_ids).distinct.pluck(:account_id).map(&:to_s)
    return if account_ids.empty?

    msp_account_id = request.headers["HTTP_PAD_MSP_ACCOUNT_ID"]
    if msp_account_id.present?
      reflected = User.msp_reflected_user_manage_users_check(user_id: user_id, msp_account_id: msp_account_id, account_ids: account_ids)
      return if reflected.authorized?
      return msp_loading_payload(reflected) if reflected.loading?
    end

    if User.user_can(user_id, "Account", "account.users.read", account_ids)
      return
    end

    raise "no authorization for #{user_id} account.users.read #{account_ids}"
  end

  def msp_loading_payload(reflected)
    {
      loading: true,
      status: reflected.status,
      loaded_count: reflected.loaded_count,
      total_count: reflected.total_count
    }
  end
end
