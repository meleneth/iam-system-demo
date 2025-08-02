require 'async'

class AccountsController < ApplicationController
  TRACER = OpenTelemetry.tracer_provider.tracer('accounts-controller', '1.0.0')

  def view
    permitted = params.permit(:as, :id)
    @as_user_id = permitted[:as]
    account_id = permitted[:id]

    Account.with_headers('pad-user-id' => @as_user_id) do
      @accounts = Account.with_parents(account_id)
    end

    @account = @accounts[-1]
    org_accounts = nil
    OrganizationAccount.with_headers('pad-user-id' => @as_user_id) do
      org_account = OrganizationAccount.find(:first, params: { account_id: @account.id })
      Organization.with_headers('pad-user-id' => @as_user_id) do
        @organization = org_account.organization if org_account
      end
      org_accounts = OrganizationAccount.find(:all, params: { organization_id: @organization.id })
    end

    #@organization_accounts = fetch_accounts_async(org_accounts.map(&:account_id))
    Account.with_headers('pad-user-id' => @as_user_id) do
      @organization_accounts = org_accounts.map {|org_account| Account.find(org_account.account_id)}
    end
    @users = User.find(:all, params: { account_id: @account.id})
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
    render :view
  end

  def fetch_parent_accounts_async()
    parent_ctx = OpenTelemetry::Context.current

    @organization_accounts = Async do |task|
      account_ids.each_slice(5).map do |group|
        task.async do
          OpenTelemetry::Context.with_current(parent_ctx) do
            TRACER.in_span("Account.fetch_group[#{group.first}-#{group.last}]") do
              Account.where(id: group).to_a
            end
          end
        end
      end.flat_map(&:wait)
    end.wait
  end

  def fetch_accounts_async(account_ids)
    parent_ctx = OpenTelemetry::Context.current

    @organization_accounts = Async do |task|
      account_ids.each_slice(5).map do |group|
        task.async do
          OpenTelemetry::Context.with_current(parent_ctx) do
            TRACER.in_span("Account.fetch_group[#{group.first}-#{group.last}]") do
              Account.with_headers('pad-user-id' => @as_user_id) do
                Account.where(id: group).to_a
              end
            end
          end
        end
      end.flat_map(&:wait)
    end.wait
  end
end
