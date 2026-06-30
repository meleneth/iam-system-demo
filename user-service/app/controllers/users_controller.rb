class UsersController < ApplicationController
  before_action :set_user, only: %i[ show update destroy ]

  # GET /users
  def index
    filters = params.slice(*User.allowed_filters).permit!
    raise BadFilterError unless filters.present?
    results = User.where(*filters)
    auth = authorize_user_collection_read!(results)
    return if performed?
    return render json: auth, status: :accepted if auth

    render json: results
  end

  # POST /users/search
  def search
    filters = params.permit(account_id: [], id: [])
    raise BadFilterError unless filters.present?

    results = User.where(*filters)
    auth = authorize_user_collection_read!(results)
    return if performed?
    return render json: auth, status: :accepted if auth

    render json: results
  end

  # GET /users/1
  def show
    auth = authorize_user_collection_read!([@user])
    return if performed?
    return render json: auth, status: :accepted if auth

    render json: @user
  end

  # POST /users
  def create
    @user = User.new(user_params)

    if @user.save
      render json: @user, status: :created, location: @user
    else
      render json: @user.errors, status: :unprocessable_entity
    end
  end

  # PATCH/PUT /users/1
  def update
    if @user.update(user_params)
      render json: @user
    else
      render json: @user.errors, status: :unprocessable_entity
    end
  end

  # DELETE /users/1
  def destroy
    @user.destroy!
  end

  private
    # Use callbacks to share common setup or constraints between actions.
    def set_user
      @user = User.find(params.expect(:id))
    end

    # Only allow a list of trusted parameters through.
    def user_params
      params.require(:user).permit(
        :account_id, :email, :username, :first_name, :last_name, :middle_name,
        :phone_number, :alt_phone, :slack_id, :avatar_url, :linkedin, :github,
        :twitter, :tshirt_size, :pronouns, :timezone, :account_id
      )
    end

  def authorize_user_collection_read!(users)
    user_id = request.headers["HTTP_PAD_USER_ID"]
    raise "no pad-user-id header sent" unless user_id
    return if user_id == "IAM_SYSTEM"

    account_ids = account_ids_for(users)
    return if account_ids.empty?

    return if User.user_can?(user_id: user_id, permission: "account.users.read", account_ids: account_ids)

    render json: { error: "forbidden" }, status: :forbidden
  end

  def account_ids_for(users)
    if users.respond_to?(:distinct)
      users.distinct.pluck(:account_id).map(&:to_s)
    else
      Array(users).map(&:account_id).map(&:to_s)
    end.uniq
  end

end
