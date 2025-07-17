class UsersController < ApplicationController
  before_action :set_user, only: %i[ show update destroy ]

  # GET /users
  def index
    filters = params.slice(*User.allowed_filters).permit!
    raise BadFilterError unless filters.present?
    results = User.where(*filters)
    render json: results
  end

  # GET /users/1
  def show
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
end
