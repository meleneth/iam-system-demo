Rails.application.routes.draw do
  namespace :internal do
    namespace :auth do
      post "account_contexts", to: "account_contexts#create"
    end

    get "msp_managed_accounts/:msp_account_id", to: "msp_managed_accounts#index"
    get "msp_managed_accounts/managed/:managed_account_id", to: "msp_managed_accounts#manager"
    get "msp_managed_accounts/:msp_account_id/:managed_account_id", to: "msp_managed_accounts#show"
  end

  get "organization_account_ids/for_account_id/:account_id", to: "organization_accounts#for_account"
  post "organization_account_ids/for_account_ids(.:format)", to: "organization_accounts#for_accounts"
  get "internal/random/organization", to: "internal/random_records#organization"
  get "internal/random/organizations/:organization_id/account", to: "internal/random_records#organization_account"

  get "/organizations/accounts/counts/:organization_id",
      to: "organizations/accounts_count#index",
      as: :organizations_account_counts

  resources :organization_accounts, only: %i[index show]
  resources :organizations, only: %i[index show]

  post "/graphql", to: "graphql#execute"
  # Define your application routes per the DSL in https://guides.rubyonrails.org/routing.html

  # Reveal health status on /up that returns 200 if the app boots with no exceptions, otherwise 500.
  # Can be used by load balancers and uptime monitors to verify that the app is live.
  get "up" => "rails/health#show", as: :rails_health_check

  # Defines the root path route ("/")
  # root "posts#index"
end
