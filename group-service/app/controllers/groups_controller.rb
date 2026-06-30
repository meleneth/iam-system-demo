class GroupsController < ApplicationController
  before_action :set_group, only: %i[ show update destroy ]

  # GET /groups
  def index
    filters = params.slice(*Group.allowed_filters).permit!
    raise BadFilterError unless filters.present?
    results = Group.where(*filters)
    auth = authorize_group_collection_read!(results)
    return render json: auth, status: :accepted if auth

    render json: results
  end

  # POST /groups/search
  def search
    filters = params.permit(account_id: [], id: [], name: [])
    raise BadFilterError unless filters.present?

    results = Group.where(*filters)
    auth = authorize_group_collection_read!(results)
    return render json: auth, status: :accepted if auth

    render json: results
  end

  # GET /groups/1
  def show
    auth = authorize_group_collection_read!([@group])
    return render json: auth, status: :accepted if auth

    render json: @group
  end

  # POST /groups
  def create
    @group = Group.new(group_params)

    if @group.save
      render json: @group, status: :created, location: @group
    else
      render json: @group.errors, status: :unprocessable_entity
    end
  end

  # PATCH/PUT /groups/1
  def update
    if @group.update(group_params)
      render json: @group
    else
      render json: @group.errors, status: :unprocessable_entity
    end
  end

  # DELETE /groups/1
  def destroy
    @group.destroy!
  end

  private
    # Use callbacks to share common setup or constraints between actions.
    def set_group
      @group = Group.find(params.expect(:id))
    end

    # Only allow a list of trusted parameters through.
    def group_params
      params.fetch(:group, {})
    end

  def authorize_group_collection_read!(groups)
    user_id = request.headers["HTTP_PAD_USER_ID"]
    raise "no pad-user-id header sent" unless user_id
    return if user_id == "IAM_SYSTEM"

    account_ids = Array(groups).map(&:account_id).map(&:to_s).uniq
    return if account_ids.empty?

    if User.user_can(user_id, "Account", "account.users.read", account_ids)
      return
    end

    raise "no authorization for #{user_id} account.users.read #{account_ids}"
  end
end
