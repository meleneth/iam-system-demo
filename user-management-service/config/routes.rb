Rails.application.routes.draw do
  get 'accounts/:id', to: 'accounts#view', as: 'account_view'
  get 'slow_accounts/:id', to: 'accounts#slow_view', as: 'slow_account_view'
  get 'slowest_accounts/:id', to: 'accounts#slowest_view', as: 'slowest_account_view'
  get "frontdoor/index"

  if Rails.env.development?
    mount GraphiQL::Rails::Engine, at: "/graphiql", graphql_path: "/graphql"
  end
  post "/graphql", to: "graphql#execute"
  # Define your application routes per the DSL in https://guides.rubyonrails.org/routing.html

  # Reveal health status on /up that returns 200 if the app boots with no exceptions, otherwise 500.
  # Can be used by load balancers and uptime monitors to verify that the app is live.
  get "up" => "rails/health#show", as: :rails_health_check

  # Render dynamic PWA files from app/views/pwa/* (remember to link manifest in application.html.erb)
  # get "manifest" => "rails/pwa#manifest", as: :pwa_manifest
  # get "service-worker" => "rails/pwa#service_worker", as: :pwa_service_worker

  # Defines the root path route ("/")
  root "frontdoor#index"
end
