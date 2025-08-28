Rails.application.routes.draw do
  # Define your application routes per the DSL in https://guides.rubyonrails.org/routing.html

  # Reveal health status on /up that returns 200 if the app boots with no exceptions, otherwise 500.
  # Can be used by load balancers and uptime monitors to verify that the app is live.
  get "up" => "rails/health#show", :as => :rails_health_check

  # Extended health check with database connection pool info
  get "health" => "health#show"

  if Rails.env.development?
    # Mount GoodJob dashboard in development only
    mount GoodJob::Engine => "/good_job"

    # Workaround for GoodJob dashboard POST vs PUT method issues
    post "/good_job/jobs/:id/force_discard", to: "good_job/jobs#force_discard"
    post "/good_job/jobs/:id/discard", to: "good_job/jobs#discard"
    post "/good_job/jobs/:id/reschedule", to: "good_job/jobs#reschedule"
    post "/good_job/jobs/:id/retry", to: "good_job/jobs#retry"
    post "/good_job/jobs/mass_update", to: "good_job/jobs#mass_update"

    # Simple Sentry smoke test route
    get "/boom", to: ->(_env) { raise "Sentry smoke test" }
  end

  # Slack webhook endpoints
  namespace :slack do
    post :commands
    post :events
    get :health
  end

  # Defines the root path route ("/")
  # root "posts#index"
  resources :positions, only: %i[index new create edit update], param: :product_id do
    member do
      post :close
      post :increase
    end
  end

  # Real-time signal API endpoints
  resources :signals, only: %i[index show] do
    collection do
      post :evaluate
      get :active
      get :high_confidence
      get :recent
      get :stats
      get :health
    end
    member do
      post :trigger
      post :cancel
    end
  end

  get "/sentiment/aggregates", to: "sentiment#aggregates"
  root to: "positions#index"
end
