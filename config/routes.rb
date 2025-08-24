Rails.application.routes.draw do
  # Define your application routes per the DSL in https://guides.rubyonrails.org/routing.html

  # Reveal health status on /up that returns 200 if the app boots with no exceptions, otherwise 500.
  # Can be used by load balancers and uptime monitors to verify that the app is live.
  get "up" => "rails/health#show", :as => :rails_health_check

  if Rails.env.development?
    # Mount GoodJob dashboard in development only
    mount GoodJob::Engine => "/good_job"

    # Simple Sentry smoke test route
    get "/boom", to: ->(_env) { raise "Sentry smoke test" }
  end

  # Defines the root path route ("/")
  # root "posts#index"
  resources :positions, only: [:index, :new, :create, :edit, :update], param: :product_id do
    member do
      post :close
      post :increase
    end
  end
  get "/sentiment/aggregates", to: "sentiment#aggregates"
  root to: "positions#index"
end
