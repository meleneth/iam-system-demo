Rails.application.routes.draw do
  post "/group_users/search(.:format)", to: "group_users#search"
  post "/groups/search(.:format)", to: "groups#search"

  resources :group_users, only: %i[index show]
  resources :groups, only: %i[index show]

  get "/accounts/groups/counts",
    to: "groups_counts#index",
    as: :groups_counts

  post "/graphql", to: "graphql#execute"
  # Define your application routes per the DSL in https://guides.rubyonrails.org/routing.html

  # Reveal health status on /up that returns 200 if the app boots with no exceptions, otherwise 500.
  # Can be used by load balancers and uptime monitors to verify that the app is live.
  get "up" => "rails/health#show", as: :rails_health_check

  # Defines the root path route ("/")
  # root "posts#index"
end
