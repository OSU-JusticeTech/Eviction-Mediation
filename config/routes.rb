Rails.application.routes.draw do
  get "mediator_cases/show"
  get "third_party_mediations/index"
  get "manage_cases/index"
  root "sessions#new"  # Home Page

  # Authentication
  get "/login", to: "sessions#new"
  post "/login", to: "sessions#create"
  get "/logout", to: "sessions#destroy"
  delete "/logout", to: "sessions#destroy"
  resources :sessions

  # Two-Factor Authentication
  get "/sms_two_factor", to: "sms_two_factor#show"
  post "/sms_two_factor/verify", to: "sms_two_factor#verify", as: "verify_sms_two_factor"
  post "/sms_two_factor/resend", to: "sms_two_factor#resend", as: "resend_sms_two_factor"

  # Dashboard Pages
  get "/dashboard", to: "dashboard#index", as: "dashboard"
  get "dashboard/landlord", to: "dashboard#landlord", as: "landlord_dashboard"
  get "dashboard/tenant", to: "dashboard#tenant", as: "tenant_dashboard"
  get "dashboard/admin", to: "dashboard#admin", as: "admin_dashboard"
  get "dashboard/mediator", to: "dashboard#mediator", as: "mediator_dashboard"

  # User Signup and Account Management
  get "/signup", to: "users#new"
  post "/signup", to: "users#create"
  resources :users

  get "/account", to: "account#show"
  get "/account/edit", to: "account#edit"
  patch "/account", to: "account#update"
  post "/account/enable_two_factor", to: "account#enable_two_factor", as: "enable_two_factor_account"
  get "/account/verify_phone", to: "account#verify_phone", as: "verify_phone_account"
  post "/account/confirm_phone", to: "account#confirm_phone", as: "confirm_phone_account"

  get "messages/tenant_show/:conversation_id", to: "messages#show", as: "tenant_show"
  get "messages/landlord_show/:conversation_id", to: "messages#show", as: "landlord_show"

  # get '/complete_screening', to: 'screenings#complete_screening'

  get "screenings/new/:conversation_id", to: "screenings#new", as: "new_screening"

  get "messages/tenant_index", to: "messages#tenant_index", as: "tenant_index"
  get "messages/landlord_index", to: "messages#landlord_index", as: "landlord_index"
  get "messages/past_mediations", to: "messages#past_mediations", as: "past_mediations"
  get "messages/landlord_past_mediations", to: "messages#landlord_past_mediations", as: "landlord_past_mediations"

  get "documents/download/:id", to: "documents#download_or_view", as: "download_file"
  get "documents/:id/view", to: "documents#show", as: "view_file"

  get "documents/generate", to: "documents#generate", as: "generate_file"
  get "documents/landlord_index", to: "documents#landlord_index", as: "landlord_documents"

  post "documents/select_template", to: "documents#select_template", as: "select_template"

  get "documents/template/:template/intake", to: "documents#template_intake", as: "template_intake"
  post "documents/template/:template/generate", to: "documents#generate_from_intake", as: "generate_from_intake"
  get "documents/template/:template/preview", to: "documents#template_preview", as: "template_preview"

  get "intake_questions/new", to: "intake_questions#new", as: "new_intake_question"
  post "intake_questions", to: "intake_questions#create", as: "intake_questions"


  get  "/documents/template_preview/:conversation_id", to: "documents#intake_template_view", as: :intake_template_view
  post "/documents/template_generate", to: "documents#generate_filled_template", as: :generate_filled_template

  post "/documents/:id/apply_signature", to: "documents#apply_signature", as: :apply_signature_document
  # Resources
  resources :messages, only: [ :index, :show, :create, :destroy ] do
    patch :request_mediator, on: :member
  end

  resources :mediator_messages, only: [ :create ]



resources :documents, only: [ :index, :new, :create, :show, :destroy ] do
  member do
    get  :download, action: :download_or_view
    get  :view_inline
    post :generate_filled_template
  end
end

  resources :resources, only: [ :index ]

  # System Data
  resource :system_data, only: [ :show ]

  # Mediations and Related Actions
  resources :mediations, only: [ :index, :new, :create, :edit, :update, :destroy ] do
    post :accept, on: :member
    post :reject, on: :member
    post :respond, on: :member
  end

  # Allow a tenant or landlord table to see previous mediations
  get "/mediation_summary/:id", to: "messages#summary", as: "mediation_summary"

  # Allow tenant or landlord to terminate a negotiation or mediation
  patch "/end_mediation/:id", to: "mediations#end_conversation", as: "end_mediation"

  # Allow tenant and landlord to fill out good faith question
  get "/good_faith_response/:id", to: "mediations#good_faith_form", as: "good_faith_response"
  patch "/good_faith_response/:id", to: "mediations#update_good_faith"
  get "/mediation_ended_prompt/:id", to: "mediations#prompt_screen", as: "mediation_ended_prompt"

  # Post-mediation survey
  get "/survey/:id", to: "mediations#survey_form", as: "mediation_survey"
  post "/survey/:id", to: "mediations#submit_survey"

  # Allow third party mediator to view cases
  resources :third_party_mediations, only: [ :index ]
  resources :mediator_cases, only: [ :show ]

  resources :screenings

  namespace :admin do
    # Admin Mediator Accounts Controller
    resources :accounts, only: [ :index, :create, :update ], controller: "accounts"


    get "mediations", to: "flagged_mediations#index"
    get "mediations/:id", to: "flagged_mediations#show", as: "flagged_mediation"
    patch "mediations/:id/reassign", to: "flagged_mediations#reassign", as: "reassign_mediator"
  end

  # Messages related ActionCable
  mount ActionCable.server => "/cable"
end
