class AccountsController < ApplicationController
  def view
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
  end
end
