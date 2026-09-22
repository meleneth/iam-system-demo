require 'async'

class AccountsController < ApplicationController
  TRACER = OpenTelemetry.tracer_provider.tracer('accounts-controller', '1.0.0')

  around_action :with_actor_context, only: %i[view slow_view slowest_view]

  def with_actor_context
    @as_user_id = params.require(:as)
    AuthorizationContext.as_requesting_user(user_id: @as_user_id) { yield }
  end

  def view
    permitted = params.permit(:as, :id)
    @as_user_id = permitted[:as]
    account_id = permitted[:id]

    TRACER.in_span("Account.with_parents(#{account_id})") do
      @accounts = Account.with_parents(account_id)
    end

    @account = @accounts[-1]
    org_accounts = nil

    TRACER.in_span("OrganizationAccount.account_ids_for_organizations_by_account_ids()") do
      response = OrganizationAccount.account_ids_for_organization_by_account_id(@account.id)
      @org_account_ids = response[:account_ids]
      @organization = response[:organization]
    end

    TRACER.in_span("fetch_accounts_async") do
      do_fetch_accounts_async = true
      if do_fetch_accounts_async then
        @organization_accounts = fetch_accounts_async(@org_account_ids)
      else
        @organization_accounts = org_accounts.map {|org_account| Account.find(org_account.account_id)}
      end
    end

    all_account_ids = @accounts.map(&:id)

    TRACER.in_span("User.search") do
      @users = User.search(account_id: all_account_ids)
    end

    prepare_user_rows
  end

  def slow_view
    @account = Account.find(params[:id])
    @accounts = []
    @accounts << @account
    current_account = @account
    while current_account.parent_account_id do
      parent_account = Account.find(current_account.parent_account_id)
      @accounts << parent_account
      current_account = parent_account
    end
    org_account = OrganizationAccount.find(:first, params: { account_id: @account.id })
    @organization = org_account.organization if org_account

    org_accounts = OrganizationAccount.find(:all, params: { organization_id: @organization.id })
    @organization_accounts = Account.where(id: org_accounts.map(&:account_id))
    @users = User.find(:all, params: { account_id: @account.id})
    prepare_user_rows
    render :view
  end

  def slowest_view
    @account = Account.find(params[:id])
    @accounts = []
    @accounts << @account
    current_account = @account
    while current_account.parent_account_id do
      parent_account = Account.find(current_account.parent_account_id)
      @accounts << parent_account
      current_account = parent_account
    end
    org_account = OrganizationAccount.find(:first, params: { account_id: @account.id })
    @organization = org_account.organization if org_account

    org_accounts = OrganizationAccount.find(:all, params: { organization_id: @organization.id })
    @organization_accounts = org_accounts.map {|org_account| Account.find(org_account.account_id)}
    @users = User.find(:all, params: { account_id: @account.id})
    prepare_user_rows
    render :view
  end

  # All rendering variants must authorize and populate the membership/group
  # records used by the shared template, under with_actor_headers.
  def prepare_user_rows
    @users_by_account_id = {}
    @users.each do |user|
      @users_by_account_id[user.account_id] ||= []
      @users_by_account_id[user.account_id] << user
    end

    all_user_ids = @users.map(&:id)
    @group_users = GroupUser.search(user_id: all_user_ids)

    all_group_ids = @group_users.map(&:group_id).uniq
    @groups = Group.search(id: all_group_ids)
    @group_name_by_group_id = {}
    @groups.each do |group|
      @group_name_by_group_id[group.id] = group.name
    end
    @group_names_by_user_id = {}
    @group_users.each do |group_user|
      @group_names_by_user_id[group_user.user_id] ||= []
      @group_names_by_user_id[group_user.user_id] << @group_name_by_group_id[group_user.group_id]
    end
  end

  def fetch_parent_accounts_async()
    parent_ctx = OpenTelemetry::Context.current
    authorization_context = AuthorizationContext.capture

    @organization_accounts = Async do |task|
      account_ids.each_slice(IamDemo.batch_size).map do |group|
        task.async do
          AuthorizationContext.with(authorization_context) do
            OpenTelemetry::Context.with_current(parent_ctx) do
              TRACER.in_span("Account.fetch_group[#{group.first}-#{group.last}]") do
                Account.search(id: group)
              end
            end
          end
        end
      end.flat_map(&:wait)
    end.wait
  end

  def fetch_accounts_async(account_ids)
    parent_ctx = OpenTelemetry::Context.current
    authorization_context = AuthorizationContext.capture

    @organization_accounts = Async do |task|
      account_ids.each_slice(IamDemo.batch_size).map do |group|
        task.async do
          AuthorizationContext.with(authorization_context) do
            OpenTelemetry::Context.with_current(parent_ctx) do
              TRACER.in_span("Account.fetch_group[#{group.first}-#{group.last}]") do
                Account.search(id: group)
              end
            end
          end
        end
      end.flat_map(&:wait)
    end.wait
  end
end
