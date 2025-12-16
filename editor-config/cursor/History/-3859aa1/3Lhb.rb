require 'auth0/api/v1'
require 'avant/api/modeling/avantapi'
require 'avant/api/phone/avantapi'
require 'avant/api/telco/avantapi'
require 'avant/api/easy/avantapi'
require 'avant/api/ciam/avantapi'
require 'avant/security/white_list_admin_access'
require 'avant/security/white_list_secure_api_access'
require 'avant/security/white_list_telco_access'
require 'avant/api/v1/root' unless Avant::Env.database_rake?
require 'avant/api/v1/admin/endpoints/root'
require 'avant/api/v1/secure/endpoints/root'
require 'avant/api/v2/root'
require 'avant/api/v3/root'
require 'avant/env'
require 'crm_engine'
require 'lockbox_engine/api'
require 'sidekiq-ent/web'
require 'payment_gateway_engine'
require 'avant/templateflow/api_endpoint'
require 'templateflow_engine/client/api_endpoint'
require 'disputes_engine'
require './platforms/account_management/modules/virtual_card/controllers/webhooks/statuses_controller'
require './platforms/account_management/modules/virtual_card/controllers/webhooks/transactions_controller'
require './platforms/account_management/modules/virtual_card/controllers/vc_transaction_search_controller'
require './platforms/account_management/modules/merchant/controllers/merchant_onboarding_controller'
require './platforms/public_api/controllers'
require 'credit_card_core'
require './platforms/public_api/controllers'
require './platforms/account_opening/modules/merchant/controllers/merchant_onboarding_controller'

Avant::Application.routes.draw do
  global_constraints = Avant::Env.private_integration? ? Security::WhiteListAdminAccess : nil

  mount Auth0::Api::V1 => '/auth0/v1'

  if Rails.env.development?
    mount GrapeSwaggerRails::Engine => '/swagger'
    mount GraphiQL::Rails::Engine, as: "admin_graphiql", at: '/graphiql', graphql_path: '/graphql'
    mount GraphiQL::Rails::Engine, as: "customer_graphiql", at: '/customer_graphiql', graphql_path: '/customer_graphql'
    mount GraphiQL::Rails::Engine, as: "customer_devtools_graphiql", at: '/customer_devtools_graphiql', graphql_path: '/customer_dev_tools_graphql'
    mount GraphiQL::Rails::Engine, as: "customers_module_graphiql", at: '/customers_module_graphiql', graphql_path: '/customers_module_graphql'
    mount GraphiQL::Rails::Engine, as: "merchant_portal_graphiql", at: '/merchant_portal_graphiql', graphql_path: '/merchant_portal_graphql'
  end

  constraints(global_constraints) do
    match "index",      to: redirect("/"), via: :all
    match "index.html", to: redirect("/"), via: :all

    get '/favicon.ico', to: proc { [404, {}, ['']] }

    if TenantConfig.content.homepage_redirects_to_login
      get '/', to: redirect('login')
    end

    # CUSTOMERS NEEDS TO BE FIRST..BEFORE ADMIN USER!!!!
    if Avant::Env::Auth0.configured?
      devise_for :customers,
                 skip: [:registrations],
                 path: '',
                 path_names: { sign_in: 'login', sign_out: 'logout' },
                 controllers: { sessions: 'customers/auth0_sessions' }

      devise_scope :customer do
        get '/auth/auth0_customer/callback' => 'customers/auth#auth_callback'
        get '/auth/failure' => 'customers/auth#failure'
        get '/auth/refresh' => 'customers/auth#refresh'
      end
    else
      devise_for :customers,
                 path: '',
                 # This prevents the following routes to be included:
                 # GET    /cancel(.:format)  devise/registrations#cancel
                 # POST   /                  devise/registrations#create
                 # GET    /sign_up(.:format) devise/registrations#new
                 # GET    /edit(.:format)    devise/registrations#edit
                 # PATCH  /                  devise/registrations#update
                 # PUT    /                  devise/registrations#update
                 # DELETE /                  devise/registrations#destroy
                 # These would potentially allow an attacker to destroy/edit his customer
                 # account
                 skip: [:registrations],
                 path_names: { sign_in: 'login', sign_out: 'logout' },
                 controllers: { sessions: 'customer_sessions', passwords: 'customer_passwords' }
    end

    resource :two_factor_authentication_challenge, only: [:new, :create, :show, :update] do
      collection { post :resend_passcode }
    end

    resource :dormant_account_authentication, only: [:show] do
      collection do
        post 'submit/reset_password', to: 'dormant_account_authentications#submit_reset_password'
        post 'submit'
      end
    end

    devise_for :admin_users, skip: [:registrations], controllers: { sessions: 'admin_users/sessions' }
    devise_scope :admin_user do
      get '/admin_users/auth/okta/callback' => 'callbacks#okta'
      get '/auth/failure' => 'callbacks#failure'
    end

    # Proxy for cards so that we can stay on one domain, see CardDashboardProxyController
    if Avant::Env.credit_card_dashboard_root.present?
      get 'activate',                to: redirect(Avant::Env.dashboard_activate_card_url)
      get 'card',                    to: redirect('/home'),               as: :card_redirect # no card context
      get 'card/activate',           to: redirect(Avant::Env.dashboard_activate_card_url)
      get 'card/:accountUuid',       to: 'card_dashboard_proxy#call',     as: :card_root, constraints: { accountUuid: /[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/ }
      get 'card/:accountUuid/*path', to: 'card_dashboard_proxy#call',     as: :card,      constraints: { accountUuid: /[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/ }
    end

    mount LockboxEngine::API => '/lockbox/api'

    mount CreditCardCore::Engine => '/credit_card_core/api'

    common_application_routes = Proc.new do
      get  :progress
      post :submit_page
      get  :current_angular_app

      # decline routes
      get  :declined_option
      get  :declined_partner_offers
      get  :notice_of_adverse_action
      get  :download_notice_of_adverse_action
      # bank_account routes
      get  :bank_names
      get  :bank_login_form
      # rates_terms routes
      get  :product_details
      post :send_product_details
      post :reject_counter_offer
      post :pull_loan_option
      # contract routes
      get  :can_view_contract_page
      get  :can_download_contract
      get  :product_options
      post :risk_based_disclosure
      # utility
      get  :needs_io
      post :submit_iovation_report
      put  :save_field
      get  :download_electronic_communications_consent
      get  :download_soft_pull_authorization
      # promotions
      post :add_promotion
      post :remove_promotion
      # hard secured
      post :drilldown
      post :multi_drilldown
      post :lookup_vehicle
      post :insufficient_collateral_reply
      # auto refinance
      get :auto_lenders
      # Explicitly log a customer_application_event
      post :track_event
      # Log whether an address was autosuggested or not
      post :set_autosuggest
      get :check_session_timeout
      delete :timeout_session
      get :neuro_id_metadata
      post :neuro_id_session_id
    end

    namespace :orig, controller: :yodlee do
      post :yodlee_ris_order_status
    end

    namespace :verify, controller: :plaid, only:[] do
      post 'plaid/asset_report_ready/:customer_application_uuid', to: 'plaid#asset_report_ready', as: :asset_report_ready
      post 'plaid/payroll_income_callback/:customer_application_uuid', to: 'plaid#payroll_income_callback', as: :payroll_income_callback
      post 'plaid/authenticate', to: 'plaid#authenticate', as: :authenticate
    end

    namespace :api do

      resources :attachment_uploads, only:[ :create ]

      mount Easy::AVANTAPI     => '/easy'
      mount Ciam::AVANTAPI     => '/ciam'
      mount Modeling::AVANTAPI     => '/modeling'
      mount Phone::AVANTAPI        => '/phone'

      mount ::Avant::Api::V1::Root => '/' if defined? ::Avant::Api::V1::Root
      mount ::Avant::Api::V2::Root     => '/v2'
      mount ::Avant::Api::V3::Root     => '/v3'

      constraints(Security::WhiteListTelcoAccess) do
        mount Telco::AVANTAPI        => '/telco'
      end

      #our yodlee api gateway controller
      resource :bank_login, only: [] do
        get   :bank_names
        get   :get_bank_by_value
        get   :login_form
        post   :submit_login_form
        get   :mfa_image
        post   :mfa_question_response
        get   :find_and_return_mfa_question
        get   :bank_lookup_by_routing_number
        # post  :find_mfa_question
      end

      resources :analytics do
        collection do
          post :log_events
        end
      end

      resources :customer_applications, only: [] do
        member do
          common_application_routes.call
        end

        resources :contracts do
          get :view_contract
          collection do
            get :details
          end
        end

        resource :contract, only: [] do
          get '/', to: 'contracts#managed_contract'
        end

        resource :payment_method_agreement, only: [] do
          get :index
          post :update
        end
      end

      resources :knowledge_based_questions, only: [:index, :create]

      namespace :card_account_service do
        resource :locations, only: [:show]
      end

      namespace :verifications do
        resources :incomes, only: [:show, :update]

        namespace :document_analysis do
          post :inscribe_callback
          post :informed_iq_callback
        end
      end

      namespace :mobile do
        namespace :v1 do
          devise_scope :customer do
            post "/sign_in", to: 'sessions#create'
            post "/sign_out", to: 'sessions#destroy'
          end
        end
      end

      resource :email_confirmation, only: [:update], controller: :email_confirmation do
        collection do
          get :resend_token
        end
      end

      resource :pos, only: [:create], controller: :pos_api do
        post :telesales
        member do
          post :authorize
          post :cancel
          post :refund
          post :status
          post :create_charge
          post :capture_charge
          post :void
          post :charge_status
          post :bulk_status
        end
      end

      resource :auto_pay_api do
        collection do
          post :issuance
          post :underwriting
          post :verifications
          post :close_app
        end
      end

      resource :verification_process, only: [:show], controller: :verification_process do
        collection do
          put :update_email
          put :confirm_personal_information
          put :confirm_bank_account_information
          post :upload_docs
          get :start_id_scan
        end
      end

      resources :contracts do
        get :view_contract
        collection do
          get :details
        end
      end

      resources :loans do
        get :payment_schedule
      end

      resource :email_bounce do
        post :bounce
      end

      scope '/9b49bc90e9240eb7d0b70a9615ad5152d77d3590b66b8a5c5867e8c4c5fcb372' do
        resource :credit_model do
          unless Rails.env.production?
            get :ping
            get :score
            match "score/:version_id/:credit_decision_id" => "credit_models#score", via: :all
            match "score/:credit_decision_id"             => "credit_models#score", via: :all
          end

          get :batch_data
          post :batch_data
          get :batch_scores
          post :batch_scores
          get :batch_source
          post :batch_source
          get :batch_source_raw
          post :batch_source_raw
          get :version_exists
          get :validation_status
        end
      end

      resource :session_timeout, only: [:show, :update, :destroy], controller: :session_timeout
      post '/refresh_token', to: 'session_timeout#refresh_token'

      scope :module => :account_opening do
        namespace :point_of_sale do
          if Avant::Env.account_opening_point_of_sale_enabled?
            # v1 is default and not part of the URL.
            scope :module => :v1 do
              post :checkout
              post :authorize
              post :status
            end

            namespace :v2 do
              post :checkout
              post :authorize
              post :status
            end
          end
        end

        namespace :leads do
          post :apply
        end

        namespace :merchant do
          get :promotional_message
        end
      end

      scope :module => :account_management do
        namespace :point_of_sale do
          post :capture_charge
          post :refund
          post :void_charge
          post :charge_status
          post :create_charge
          post :cancel
        end
      end

      namespace :account_opening do
        get 'applications/:application_uuid/applicant_provided_data', to: 'business#applicant_provided_data'
        get 'applications/:application_uuid/outbound_partner_api_responses', to: 'business#outbound_partner_api_responses'
        get 'applications/:application_uuid/inbound_partner_api_requests', to: 'business#inbound_partner_api_requests'
        post 'invitation' => 'invitation#invitation'

        unless Avant::Env.production_env?
          post 'data_contracts/publish_applications', to: 'data_contract#publish_applications'
        end
      end

      post '/account_opening/auth/token', to: 'partner_api_manager/inbound_request#auth_token'
      post '/account_opening/inbound_request/:request_identifier', to: 'partner_api_manager/inbound_request#process_inbound_request'
      post '/account_opening/business/upload', to: 'account_opening/business#upload'

      post '/account_management/auth/token', to: 'account_management#auth_token'
      post '/account_management/webhook/:request_identifier', to: 'account_management#process_inbound_request'
      get '/account_management/contract/pdf/:account_uuid' => 'account_management#contract_pdf'

      namespace :account_management do
        get '/loan_core/contract/pdf/:account_uuid' => 'loan_core#contract_pdf'
      end

      namespace :v3 do
        post '/customer_management/auth/token', to: 'customer_management/partner_request#auth_token'
        post '/customer_management/inbound_request/:request_identifier', to: 'customer_management/partner_request#process_inbound_request', as: 'process_inbound_request'
      end

      scope :configurables do
        get '/',      to: "configurable#index"
        post '/auth', to: "configurable#create_session"
      end
    end

    # Secure API
    constraints(Security::WhiteListSecureApiAccess) do
      namespace :secure do
        namespace :api do
          mount ::Avant::Api::V1::Secure::Endpoints::Root => '/'
          namespace :business_gateway do
            namespace :account_management do
              namespace :virtual_card do
                namespace :webhooks do
                  resource :statuses,
                           controller: '/account_management/virtual_card/webhooks/statuses',
                           only: [:create]
                  resource :transactions,
                           controller: '/account_management/virtual_card/webhooks/transactions',
                           only: [:create]
                end
                resource :vc_transaction_search,
                         controller: '/account_management/virtual_card/vc_transaction_search',
                         only: [:create]
              end
            end
          end

          namespace :merchants_service do
            namespace :account_management do
              resource :merchant,
                        controller: '/account_management/merchant/merchant_onboarding',
                        only: [:create]
            end
            namespace :account_opening do
              resource :merchant,
                       controller: '/account_opening/modules/merchant/controllers/merchant_onboarding',
                       only: [:create]
            end
          end

          namespace :rest do
            resources :customers, param: :uuid, only: [:show], controller: '/public_api/controllers/customers' do
              resources :addresses, param: :uuid,
                        controller: '/public_api/controllers/addresses',
                        only: [:index, :update]
              resources :email_addresses,
                        controller: '/public_api/controllers/email_addresses',
                        only: [:index, :create]
              resources :housing,
                        controller: '/public_api/controllers/housing',
                        only: [:index]
              resources :bank_accounts,
                        controller: '/public_api/controllers/bank_accounts',
                        only: [:index, :create]
              resource :income,
                        controller: '/public_api/controllers/incomes',
                        only: [:index, :show, :update]
              resource :consents,
                        controller: '/public_api/controllers/consent',
                        only: [:show, :update]
              resources :phone_numbers, param: :uuid,
                        controller: '/public_api/controllers/phone_numbers',
                        only: [:index, :create, :update]
              resources :servicing_accounts,
                        controller: '/public_api/controllers/servicing_accounts',
                        only: [:index]
            end

            resources :servicing_accounts, param: :uuid, only: [:show], controller: '/public_api/controllers/servicing_accounts' do
              resources :payments, param: :uuid,
                       controller: '/public_api/controllers/payments',
                       only: [:index, :update]
              resource :payoff_information,
                       controller: '/public_api/controllers/payoff_information',
                       only: [:show]
              resources :charge_offs,
                       controller: '/public_api/controllers/charge_offs',
                       only: [:index]
            end
          end
        end
      end
    end

    constraints(Security::WhiteListAdminAccess) do
      authenticate :admin_user do
        mount Sidekiq::Web, at: '/sidekiq'
        resources :dark_credit_decision_diffs_grid
      end

      mount Coverband::Reporters::Web.new, at: '/coverage'

      mount CrmEngine::Engine => '/admin2'

      namespace :admin do

        namespace :api do
          mount ::Avant::Api::V1::Admin::Endpoints::Root => '/'
        end

        namespace :v2 do
          match '/customer/:customer_id/:workflow', to: 'workflows#customer', as: 'customer_workflow', via: [:get, :post]
          match '/admin_user/:admin_user_id/:workflow', to: 'workflows#admin_user', as: 'admin_user_workflow', via: [:get, :post]
          match '/customer_application/:customer_application_uuid/:workflow', to: 'workflows#customer_application', as: 'customer_application_workflow', via: [:get, :post]

          match '/ivr/:workflow', to: 'workflows#ivr', as: 'ivr_workflow', via: [:get, :post]

          match '/:object_type/:object_id/diagnose', to: 'admin_v2#diagnose', as: 'diagnose', via: [:get]
          match '/:product_type/:product_id/loan_tasks', to: 'loan_tasks#index', as: 'loan_tasks_show', via: :get

          resources :loan_tasks do
            member do
              post :cancel
              post :commit
              post :return
              post :forgive
              post :forgive_nsf
              post :process_commit
            end
          end

          match '/:product_type/:product_uuid/download_payment_breakdown', to: 'download_payment_breakdowns#download_file', as: 'download_payment_breakdown_file', via: [:get]
          # This must be declared after loan tasks
          match '/:product_type/:product_id/:workflow', to: 'workflows#product', as: 'product_workflow', via: [:get, :post]
        end

        Admin::DocumentsController.templates.each do |template|
          get "/documents/#{template}/:product_type/:product_id" => "documents##{template}", as: template
        end

        resources :verification_engines
        match '/verification_tasks/:product_type/:product_uuid/:name/update', to: 'verification_tasks#update', as: 'verification_tasks_update', via: [:put, :post, :patch]
        match '/:product_type/:product_id/:engine/show', to: 'verification_engines#show', as: 'verification_engines_show', via: :get

        resource :analytics do
          get :validation
          get :rescore
          post :rescore
        end

        resources :admin_users, only: [:index] do
          member do
            get :change_queues
            put :punch_queue
            put :reset_password
          end
        end

        resource :notifications do
          get :messages
        end

        resource :data_visualizations, only: [] do
          get :introspection_search
          get :category_viewer
          get :data_source_viewer
        end

        resources :promotions do
          collection do
            post :add_promotion_to_product
            post :remove_promotion_from_product
            post :create_promotion_loan_task
            post :bulk_create_promotions
            get :fetch_card_configs
            get :fetch_loan_configs
            get :bulk_upload
            get :example_promotion_file
          end
        end

        resources :promotion_instance, :only => [:index, :show]

        resources :reports

        resources :draws do
          member do
            post :book
          end
        end

        resources :customers do
          collection do
            get :search
            get :yodlee_data_viewer_tag_search
          end

          member do
            get :kba
            get :credit_reports
            get :applications
            get :credit_report
            get :clarity_credit_report
            get :credit_report_xml
            get :neustar_credit_report
            get :yodlee_bank_data
            get :ovt_bank_data
            get :bank_details
            get :yodlee_data_viewer
            get :ovt_data_viewer
            get :yodlee_iav_data
            post :yodlee_data_viewer_save
            post :ovt_data_viewer_save
            post :yodlee_data_viewer_classification_save
            post :customer_email
            get :loans
            get :credit_lines
            get :notes
            get :email
            get :email_details
            get :email_raw
            get :credit_decisions
            get :iovation_report
            post :send_verification_email
            post :send_verify_identity_jumio_email
            post :resend_confirmation_email
            post :run_credit_report
            post :run_rapleaf_report
            post :create_note
            post :create_credit_report
            get :login
            post :login
            post :decline
            post :expire_lockout
            post :rerun_decision
            post :force_yodlee
            get :force_yodlee # get is for api
            post :send_mail
            post :toggle_active
            post :deactivate_debit_cards
            get :feed
            post :toggle_fraud_confirmed
            get :associated_accounts
          end

          resources :customer_fraud_reasons do
            collection do
              post :add_remove
            end
          end

          resources :bankruptcies, only: [:create,:destroy]

          resources :attachments do
            collection do
              get :uploads
              post :create_upload
            end

            member do
              put :update_status
              post :duplicate
            end
          end

        end

        resources :market_place_files do
          member do
            get :csv_ready
            get :cancel_file
            get :sell_file
            get :final_csv
            get :rejected_csv
            get :get_debugging_info
            put :sub_purchaser
          end
        end

        resources :market_place_purchasers, only: [:index] do
          member do
            post :reactivate
            post :deactivate
            post :populate_eligibility
            post :update_loan_age_range
            post :update_final_sale_day_of_the_week
          end
        end

        resources :market_place_sub_purchasers do
          member do
            post :activate
          end
        end

        resources :loans do
          collection do
            get :search
            get :samples
          end

          member do
            get :notes
            get :view_contract
            get :view_buckets
            get :view_rbpn
            get :installments
            get :view_terms_table
            get :view_fraud_decision
            get :heal
            get :view_link
            get :project_payment_schedule
            get :preview_payment
            get :historical_days_late
            post :create_note
            post :pay
          end

          resources :metro_requests, only: [:update, :index] do
            collection do
              get 'exclude_from_metro_file'
              get 'regenerate'
              get 'generate_update_summary'
            end
          end
        end

        resources :loan_tasks do
          member do
            post :commit
            post :process_commit
          end
        end

        resources :notes do
          collection do
            get :admin_users
          end
        end

        resources :installments

        root :to => "customers#search", via: :all

        resources :work_items do
          member do
            post :transition
            get  :status
          end

          collection do
            get :loc

            # LP
            get :legal
            get :pre_ver_decisioning
            get :pre_ver_processing
            get :hard_secured
            get :refinance_processing
            get :refinance_ready
            get :refinance_tl_review
            get :refinance_waiting
            get :refinance_not_issuable_today
            get :reject_review
            get :auto_reject
            get :regions
            get :fraud
            get :fraud_waiting
            get :lp
            get :cl
            get :tl_review
            get :lp_ready
            get :lp_outbound
            get :lp_autoapprovals
            get :lp_webbank
            get :lp_false_contracts
            get :lp_processing
            get :lp_waiting
            get :lp_dashboard
            get :model_declined
            get :letter_declined
            get :mine
            get :refresh
            post :enqueue
            get :ast
            get :collections
          end
        end

        resources :metro, controller: 'metro_files' do
          member do
            get :get_data
            put :mark_sent
            put :mark_unsent
            get :compile
          end
        end

        post "pusher/auth"

        resources :rollout_timestamps, only: [:index]
      end

      get '/servicing' => 'servicing#index', as: 'servicing_index'

      namespace :servicing do
        resources :cardmember_agreements, only: [:index, :create] do
          collection do
            get '/sample_csv_file' => 'cardmember_agreements#download_sample_csv'
            get '/guidelines' => 'cardmember_agreements#guidelines'
          end
        end

        resources :scra_periods, only: [:index, :create] do
          collection do
            get '/sample_csv_file' => 'scra_periods#download_sample_csv'
            get '/guidelines' => 'scra_periods#guidelines'
          end
        end

        resources :dsars, only: [:index] do
          collection do
            post :download
          end
        end

        resources :create_dmc_settlements, only: [:index, :create] do
          collection do
            get '/sample_csv_file' => 'create_dmc_settlements#download_sample_csv'
            get '/guidelines' => 'create_dmc_settlements#guidelines'
            get '/status' => 'create_dmc_settlements#status'
            get '/latest_response_log_file' => 'create_dmc_settlements#download_latest_response'
            get '/batch_job_response' => 'create_dmc_settlements#download_response_for_batch_job'
          end
        end
      end

      get '/treasury' => 'treasury#index', as: 'treasury_index'

      namespace :treasury do
        resources :blinds, only: [:create, :index], param: :payment_method do
          resources :tests, only: [:create, :index], controller: 'blinds/tests'
        end

        resources :prime_rates, only: [:create, :index, :update, :destroy, :new]

        get '/debt_sales/sample_csv_file' => 'debt_sales#download_sample_csv'
        resources :debt_sales, only: [:index,:create,:show]

        get '/debt_sale_rebuys/sample_csv_file' => 'debt_sale_rebuys#download_sample_csv'
        resources :debt_sale_rebuys, only: [:index,:create,:show]

        get '/deal_economics/sample_csv_file' => 'deal_economics#download_sample_csv'
        resources :deal_economics, only: [:index, :create]

        resources :contract_batches, only: [:index,:create,:show] do
          collection do
            get '/sample_csv_file' => 'contract_batches#download_sample_csv'
            get '/guidelines' => 'contract_batches#guidelines'
          end
        end

        resources :financial_owners, only: [:index, :create, :show] do
          collection do
            get '/guidelines' => 'financial_owners#guidelines'
          end

          member do
            post :invalidate
            post :activate
            post :toggle_status
          end
        end

        resources :financial_owner_bank_accounts, only: [:new, :create] do
          member do
            post :invalidate
            post :activate
            post :toggle_status
          end
        end

        resources :terminations, only: [:index, :create, :show] do
          collection do
            get 'sample_csv_file' => 'terminations#download_sample_csv'
          end

          member do
            post :process_termination
            post :cancel
          end
        end
        resources :termination_reasons, only: [:index, :create]

        resources :webbank_servicings, only: [:index] do
          collection do
            get 'sample_csv_file' => 'webbank_servicings#download_sample_csv'
            get 'guidelines' => 'webbank_servicings#guidelines'

            post :update_loss_rates
            post :update_purchase_premium
          end
        end

        resources :contract_verifications, only: [:index,:create,:show] do
          collection do
            get '/sample_csv_file' => 'contract_verifications#download_sample_csv'
            get '/sample_csv_response_file' => 'contract_verifications#download_sample_response_csv'
            post :upload_response_csv
          end

          member do
            get :upload_csv
            get :output_csv
            get :response_csv
          end
        end

        resources :product_taggings, only: [:index, :create] do
          collection do
            get '/sample_csv_file' => 'product_taggings#download_sample_csv'
            get '/guidelines' => 'product_taggings#guidelines'
          end

          member do
            get :upload_csv
            get :errors_csv
            get :confirmation_csv
            post :process_batch
            post :cancel
          end
        end

        resources :market_place_sub_purchasers, only: [:index, :create] do
          collection do
            get '/sample_csv_file' => 'market_place_sub_purchasers#download_sample_csv'
            get '/guidelines' => 'market_place_sub_purchasers#guidelines'
          end

          member do
            get :upload_csv
            get :errors_csv
            post :process_batch
            post :cancel
          end
        end

        resources :metro_file_batches, only: [:index, :create] do
          member do
            get :upload_csv
            get :errors_csv
          end
        end

        resources :issuance_files, only: [:index, :show, :create, :destroy] do
          member do
            get :errors
            post :send_file
          end
        end

        resources :deal_economics, only: [:index, :show]

        namespace :bank_files do
          resources :refunds, only: [:index, :create, :show] do
            member do
              post :cancel
              post :send_file
            end
          end
        end

        resources :admin_user_signoffs, only: :create

        namespace :credit_cards do
          resources :gateway_payments, only: [:index] do
            collection do
              get :download
              post :reset
              post :regenerate
              post :send_payments
              post :toggle_sending
            end
          end
          resources :fdr_payments, only: [:index] do
            collection do
              get :download
              get :reset
              get :regenerate
              get :mark_sent
            end
          end
          resources :refunds, only: [:index, :create]
          resources :return_payments, only: [:index] do
            collection do
              get :download
              get :reset
              get :regenerate
              get :mark_sent
            end
          end
        end
      end
    end # end WhiteListAdminAccess constraint

    scope :leads, controller: 'leads', path: 'leads' do
      # Prefill route with obligatory api_token is deprecated
      match "prefill/:lead_provider(/:api_token)"        => "leads#prefill",      :as => "leads_prefill", via: :all
      match "inbound(/:lead_provider)(/:variant)"      => "leads#inbound",      :as => "leads_inbound", via: :all
      match "process_lead(/:lead_provider)(/:variant)" => "leads#process_lead", :as => "leads_process", via: :all
    end
    scope :leads, controller: 'lead_credit_cards', path: 'leads' do
      match "credit_cards/inbound(/:lead_provider)(/:variant)"      => "lead_credit_cards#inbound",      :as => "lead_credit_cards_inbound", via: :all
    end


    if ENV['TEST_CUSTOMERS_ENABLED']
      match "fix_customer" => "sandbox#fix_customer", via: :all
    end

    if !Rails.env.production?
      scope :sandbox, :controller => "sandbox", :path => "sandbox" do
        # In case these routes are still used locally, explicitly assign routes to these
        # actions, instead of using (:action) matcher, which is deprecated in Rails 5
        %w[local_trap action_missing fix_customer pdf_sample].each do |action|
          match action => "sandbox##{action}", via: :all
        end
        # I assume this was a mistake since this will generate "/sandbox/sandbox/local_trap" route. But in case
        # this was made intentionally, will just keep it.
        match "sandbox/local_trap" => "sandbox#local_trap", via: :all
      end

      match "pl"    => "sandbox#post_lead",         :as => "post_lead_shortcut", via: :all
      match "c/:id" => "sandbox#login_as_customer", :as => "login_as_customer",  via: :all
      match "l/:id" => "sandbox#login_by_loan",     :as => "login_by_loan",      via: :all
    end

    post '/bootstrap_session' => 'bootstrap_session#create'

    scope controller: :demo do
      get "demo/:partner/:product_type/:page", to: "demo#components"
      get "demo/:page", to: "demo#components"
    end

    unless TenantConfig.content.disable_content_controller
      match "press_release/:release", controller: "content", action: "press_release", via: :all
      scope controller: :content do
        get :profile_memory
        # get '/robots.txt' => 'content#robots'
        get :index
        # NOTE: Historically used for testing an alternate index. The alternate index
        # was removed but this route/action has been retained for SEO purposes
        get :index2, to: redirect("/index")
        get :r
        get :testimonials
        get "rates_terms" => "content#rates_terms", :as => :rates_terms
        get :faq
        get :referral_faq
        get :privacy_policy
        get :privacy_notices
        get :privacy_notice
        get :webbank_privacy_notice
        get :terms_of_use
        get :cardmember_agreement
        get "/sms" => "content#sms_terms_conditions", :as => :sms_terms_conditions
        get :mobile_faq
        get :mobile_faq_bare
        get :about_us
        get :contact
        get :jobs
        get "/powered-by-avant" => "content#powered_by_avant", :as => :powered_by_avant
        post :powered_by_avant_demo
        get :press
        get :mobile
        get :third_party
        get "/personal-loans" => "content#personal_loans", :as => :personal_loans
        get "/secured-loans" => "application#not_found", :via => :all
        get "/auto-loans" => "application#not_found", :via => :all
        get "/what_is_a_personal_loan" => "content#about_personal_loans", :as => :about_personal_loans
        get "/about_personal_loans", to: redirect("/what_is_a_personal_loan")
        get "avant_comparison/debt_consolidation_loans" => "content#debt_consolidation", :as => :debt_consolidation
        get "avant_comparison/payday_loans" => "content#payday_loans", :as => :payday_loans
        get :avant_comparison
        get :personal_loans_qa
        get :personal_offer_code
        post :personal_offer_code
        # The following two paths are equivalent; card_offer exists because we
        # initially used this route for credit card offers
        post "/personal_offer_code_async" => "content#personal_offer_code_async"
        post "/card_offer" => "content#personal_offer_code_async"
        get "/loan_uses/debt_consolidation_benefits" => "content#debt_consolidation_benefits", :as => :debt_consolidation_benefits
        get "/debt_consolidation_benefits", to: redirect("/loan_uses/debt_consolidation_loans")
        get :what_is_an_unsecured_loan
        post :trap
        get "landing/facebook_dm" => "content#facebook_landing"
        match "landing(/:landing_keyword)" => "content#custom_landing_page", :via => :all
        get :loan_uses
        get "/loan_uses/debt_consolidation_loans" => "content#debt_consolidation_loans", :as => :debt_consolidation_loans
        get "/loan_uses/home_improvement_loans" => "content#home_improvement_loans", :as => :home_improvement_loans
        get "/loan_uses/emergency_loans" => "content#emergency_loans", :as => :emergency_loans
        match "/debt_consolidation_loans", to: redirect("/loan_uses/debt_consolidation_loans"), via: :all
        match "/home_improvement_loans", to: redirect("/loan_uses/home_improvement_loans"), via: :all
        match "/emergency_loans", to: redirect("/loan_uses/emergency_loans"), via: :all
        get :accessibility
        get :scra
        get :myoffer
        get "offer" => "content#myoffer"
        post :ppc_traffic
        get "branch" => "content#in_branch_landing"
        get "business" => "content#business"
        get "checkout" => "content#checkout"
        get :strategy_param_error
      end
    end

    resource :customer do
      get   :index
      get   :dashboard
      post  :facebook_login
      get   :send_confirmation_email
      get   :home
      get   :account_settings
      get   :account_history
      get   :csrf_token
      post  :pusher_auth
      scope '/ajax' do
        get :activities
      end
    end

    scope '/loss_mitigation', controller: :loss_mitigation do
      get 'mark_active_loss_mitigation_offer_as_viewed/:loan_uuid', action: :mark_active_loss_mitigation_offer_as_viewed
      get 'mark_offered_settlement_offer_as_viewed/:loan_uuid', action: :mark_offered_settlement_offer_as_viewed
    end

    resources :payments do
      scope '/ajax' do
        get :next_monthly_payment, on: :collection
      end
    end

    resources :partner_offers, only: [:show] do
      post :mark_viewed
    end
    get 'partner_offers/process/engine/:id', to: 'partner_offers#redirect_engine'
    post 'partner_offers/process/engine/:id', to: 'partner_offers#process_engine', as: 'partner_offers_process_engine'
    get 'partner_offers/process/pagaya_ndr/:id', to: 'partner_offers#pagaya_ndr', as: 'partner_offers_process_pagaya_ndr'

    # resources :contracts
    resource :contract do
      get :view_contract
      get :print
      get :view_ltpp
      get :view_settlement
      get :view_payment_plan
    end

    resource :bank_account

    resources :loans do
      get :payment_schedule
      scope '/ajax' do
        get :payoff_amount
      end
    end

    resource :payment_method_agreement, only: [] do
      get :view
      get :print
    end

    resources :credit_lines do
      resources :draws
      resources :periods, only: [:index, :show] do
        get :statement
      end
      get :monthly_minimum_charge_table
      match 'statement_test' => 'periods#statement_test', via: :all
    end

    resource :verify, :controller => "verify" do
      get :account
      get :progress
    end

    resources :customer_applications, only: [:index, :show], path: :apply, :controller => :apply do
      collection do
        post :submit_short_form
        get :leads
        get :prefill_leads
        get :risk_based_info
        get :send_recovery_email
        get :existing_account
        get :recover
        get :report
        get :referrals
        get :refinance
      end
      member do
        post :check_turnstile
        get :declined_redirect
      end
    end

    devise_scope :customer do
      get "welcome_back", to: "customer_sessions#welcome_back"
      get "clear_welcome_back", to: "customer_sessions#clear_welcome_back"
      get "restart_application", to: "customer_sessions#restart_application"
      get "existing_account", to: "customer_sessions#existing_account"
      get "/whoami" => "customer_sessions#whoami"
    end
    get "dashboard", to: "customers#new_dashboard"
    # The following route supports Android-compatible deep links, which cannot
    # contain '#'.
    get 'dr/:dashboard_anchor', to: redirect('dashboard#/%{dashboard_anchor}')
    get "home", to: "customers#new_customer_home", as: :new_customer_home
    get "account_settings", to: "customers#account_settings", as: :account_settings
    get "account_history", to: "customers#account_history", as: :account_history

    get "refinance/apply", to: "refinance#apply"

    get 'affiliate', to: 'affiliates#affiliate'
    match "affiliates/thank_you" => 'affiliates#confirmation_page', as: :confirmation_page, via: :all

    resources :affiliates, :only => [:new, :create]

    get 'identity_verification', to:'jumio#start'
    get 'identity_verification/finish', to:'jumio#break_out_of_iframe'
    get 'identity_verification/completed', to:'jumio#completed'
    get 'identity_verification/error', to:'jumio#error'
    post 'identity_verification/callback', to:'jumio#callback'

    get 'kba/start',      to: 'kba#start',     as: 'kba_start'
    get 'kba/later',      to: 'kba#later',     as: 'kba_later'
    match 'kba/question', to: 'kba#question',  as: 'kba_question', via: [:get, :post]

    # Aon SSO/SAML login for Payment Protection
    get "sso/payment_protection", to: "saml#payment_protection"

    # Payment Gateway specific
    mount PaymentGatewayEngine::Client::ApiEndpoint => '/payment_gateway'

    # Templateflow specific
    mount TemplateflowEngine::Client::ApiEndpoint => '/templateflow'

    # Disputes specific
    mount DisputesEngine::Client::ApiEndpoint => '/disputes'

    # GraphQL in Development
    if Avant::Env.debug_graphql?
      get '/graphql', to: 'graph#graph'
      post '/graphql', to: 'graph#graph'
      match '/customer_graphql', to: 'graph#customer_graph', via: [:get, :post, :options]
      match '/customer_dev_tools_graphql', to: 'graph#customer_dev_tools_graph', via: [:get, :post, :options]
      match '/customers_module_graphql', to: 'graph#customers_module_graph', via: [:get, :post, :options]
      match '/merchant_portal_graphql', to: 'graph#merchant_portal_graph', via: [:get, :post, :options]
    end

    get "/robots.txt" => "robots#robots", :format => "text"

    unless TenantConfig.content.disable_blog_controller
      get "/:blog" => "blog#show", :constraints => {blog: /blog(\/.*)?/}
    end

    if TenantConfig.content.disable_content_controller
      root to: "application#not_found", via: :all
    else
      root to: "content#index", via: :all
      match ":landing_keyword" => "content#custom_landing_page", :via => :all
    end

    match "/change" => redirect("/landing/change"), :via => :all

    get 'customer_emails/confirm/:token' => "customer_emails#confirm", as: :customer_email_confirmation
    get 'customer_application_email/:customer_application_uuid/confirm/:token' => "customer_application_email#confirm", as: :customer_application_email_confirmation

    scope '/point_of_sale', controller: :point_of_sale do
      get ':token' => 'point_of_sale#index', as: :point_of_sale_landing
      get 'approved/:customer_application_id' => 'point_of_sale#approved', as: :point_of_sale_approved
      get 'declined/:customer_application_id' => 'point_of_sale#declined', as: :point_of_sale_declined
    end

    scope '/in_branch', controller: :in_branch do
      get 'apply_with_token/:token' => 'in_branch#apply_with_token', as: :in_branch_apply_with_token
      post 'apply' => 'in_branch#apply', as: :in_branch_apply
    end

    scope '/sms', controller: :sms do
      post 'telesign' => 'sms#telesign_callback', as: :sms_telesign_callback
    end

    unless Avant::Env.production_env?
      get 'e2e/next_ssn_for_test_case', to: 'e2e#next_ssn_for_test_case'
      get 'e2e/new_application_with_experiments', to: 'e2e#new_application_with_experiments'
      get 'e2e/test_cases', to: 'e2e#test_cases'
      post 'e2e/raise_risk', to: 'e2e#raise_risk'
      post 'e2e/advance_to_stage', to: 'e2e#advance_to_stage'
      get 'e2e/current_app_stage', to: 'e2e#current_app_stage'
      get 'e2e/current_app_verification_stage', to: 'e2e#current_app_verification_stage'
      get 'e2e/action_status', to: 'e2e#action_status'
      get 'e2e/failed_risk_summary', to: 'e2e#failed_risk_summary'
      get 'e2e/policy_owner', to: 'e2e#policy_owner'
      get 'e2e/fetched_reports', to: 'e2e#fetched_reports'
      get 'e2e/application_info', to: 'e2e#application_info'
      get 'e2e/mitigation_status', to: 'e2e#mitigation_status'
      get 'e2e/loan_status', to: 'e2e#loan_status'
      post 'e2e/change_application_date', to: 'e2e#change_application_date'
      post 'e2e/simulate_payment_history', to: 'e2e#simulate_payment_history'
    end

    # New endpoint added for cross sell
    # TODO: point to generic controller to open up endpoint to use cases beyond cross sell uil
    get 'loan/apply', to: 'account_opening/cross_sell#apply'
    get 'credit_card/apply', to: 'account_opening/credit_card#apply'

    namespace :account_opening do

      scope :point_of_sale do
        get 'loan_confirmation' => 'point_of_sale#loan_confirmation'
        get ':token' => 'point_of_sale#index', as: :point_of_sale_landing
        get 'customer/checkout' => 'point_of_sale#customer_checkout', as: :point_of_sale_customer_checkout
        get 'new_customer/checkout' => 'point_of_sale#new_customer_checkout', as: :point_of_sale_new_customer_checkout
      end

      scope :notice do
        get 'pdf/:token' => 'notice#pdf_from_token', as: :pdf_from_token
      end

      scope :apply do
        get 'application/:application_uuid' => 'g2_apply#frontend_application_redirect', as: :application
        get 'sign_in/:application_uuid' => 'g2_apply#redirect_to_sign_in', as: :sign_in
        get 'guest_application/:application_uuid/:token' => 'g2_apply#frontend_guest_application_redirect', as: :guest_application

        get 'request_application_transfer/:application_uuid' => 'application_transfer#request_application_transfer'
        get 'accept_application_transfer/:application_uuid' => 'application_transfer#accept_application_transfer'
        post 'allowed_actions' => 'g2_apply#allowed_actions'
        post 'autofill_personas' => 'g2_apply#autofill_personas'
        post 'chosen_offer' => 'g2_apply#chosen_offer'
        post 'offer_summary' => 'g2_apply#offer_summary'
        get 'customer_home_redirect' => 'g2_apply#customer_home_redirect'
        post 'data/get' => 'g2_apply#get_applicant_data'
        post 'data/submit' => 'g2_apply#submit_applicant_data'
        post 'persist_password' => 'g2_apply#persist_password'
        post 'decline_scenario' => 'g2_apply#decline_scenario'
        post 'identifiers' => 'g2_apply#identifiers'
        post 'journey_information' => 'g2_apply#journey_information'
        post 'merchant_information' => 'g2_apply#merchant_information'
        get 'notice/pdf/:application_uuid/:notice_uuid' => 'g2_apply#notice_pdf', as: :notice_pdf
        get 'contract/pdf/:application_uuid' => 'g2_apply#contract_pdf', as: :contract_pdf
        post 'notice_consent' => 'g2_apply#notice_consent'
        post 'notice_content' => 'g2_apply#notice_content'
        post 'notice_view' => 'g2_apply#notice_view'
        post 'offers' => 'g2_apply#offers'
        post 'page_submission' => 'g2_apply#page_submission'
        post 'page_submissions' => 'g2_apply#page_submissions'
        post 'partner_bank_account_options' => 'g2_apply#partner_bank_account_options'
        post 'partner_information' => 'g2_apply#partner_information'
        post 'redirect_urls' => 'g2_apply#redirect_urls'
        post 'loan_booking_api_response' => 'g2_apply#loan_booking_api_response'
        post 'set_selected_offer' => 'g2_apply#set_selected_offer'
        post 'submit_iovation_metadata' => 'g2_apply#submit_iovation_metadata'
        post 'trigger_action' => 'g2_apply#trigger_action'
        post 'reset_apply_session_timeout' => 'g2_apply#reset_apply_session_timeout'
        get 'verifications_redirect' => 'g2_apply#verifications_redirect'
        get 'vcn_redirect' => 'g2_apply#vcn_redirect'
        post 'get_contract' => 'g2_apply#get_contract'
        post 'get_loan_id' => 'g2_apply#get_loan_id'
        post 'sign_contract' => 'g2_apply#sign_contract'
        post 'view_stage' => 'g2_apply#view_stage'
        post 'existing_bank_accounts' => 'g2_apply#existing_bank_accounts'
        post 'existing_debit_cards' => 'g2_apply#existing_debit_cards'
        post 'has_hard_inquiry' => 'g2_apply#has_hard_inquiry'
        post 'credit_card_strategy_details' => 'g2_apply#credit_card_strategy_details'
        post "get_co_brand_card_choice" => "g2_apply#get_co_brand_card_choice"
        post "choose_co_brand_card_art" => "g2_apply#choose_co_brand_card_art"
        post "customer_lookup" => "g2_apply#customer_lookup"
        post "internal_customer_lookup" => "g2_apply#find_matches_and_merge_applicant"
        post 'bureau_details' => 'g2_apply#bureau_details'
        post 'channel' => 'g2_apply#channel'
        post 'source' => 'g2_apply#source'

        scope :verification do
          post 'dashboard_items' => 'verification#dashboard_items'
          post 'mitek_upload_image' => 'verification#mitek_upload_image'
          post 'mitek_fetch_report' => 'verification#mitek_fetch_report'
          post 'mitek_document_upload_email' => 'verification#mitek_document_upload_email'
          post 'upload_document' => 'verification#upload_document'
          post 'multi_document_upload' => 'verification#multi_document_upload'
          post 'resend_confirmation_email' => 'verification#resend_confirmation_email'
          post 'confirm_ssn' => 'verification#confirm_ssn'
          post 'validate_address' => 'verification#validate_address'
          post 'confirm_dob' => 'verification#confirm_dob'
          post 'send_mfa_code' => 'verification#send_mfa_code'
          post 'verify_mfa_code' => 'verification#verify_mfa_code'
          post 'phone_verification_status' => 'verification#phone_verification_status'
          post 'confirm_bank_account' => 'verification#confirm_bank_account'
          post 'unlock_credit_report' => 'verification#unlock_credit_report'
          post 'plaid_link_token' => 'verification#plaid_link_token'
          post 'plaid_connect' => 'verification#plaid_connect'
          post 'accept_counter_offer' => 'verification#accept_counter_offer'
          post 'add_additional_income' => 'verification#add_additional_income'
          unless Avant::Env.production_env?
            scope :dev_tools do
              post 'confirm_ssn', to: 'verification_dev_tools#confirm_ssn'
              post 'confirm_dob', to: 'verification_dev_tools#confirm_dob'
              post 'confirm_bank_account', to: 'verification_dev_tools#confirm_bank_account'
              post 'confirm_email', to: 'verification_dev_tools#confirm_email'
              post 'email_confirmation_link', to: 'verification_dev_tools#email_confirmation_link'
              post 'complete_current_action', to: 'verification_dev_tools#complete_current_action'
              post 'customer_reliant_mitigations', to: 'verification_dev_tools#customer_reliant_mitigations'
              post 'trigger_mitigation', to: 'verification_dev_tools#trigger_mitigation'
            end
          end
        end
      end

      scope :branding do
        post "card_options" => "branding#card_options"
        post "co_brand_logo" => "branding#co_brand_logo"
      end

      scope :leads do
        get ':token' => 'leads#index', as: :leads_landing
      end

      get 'invitation' => 'invitation#claim'
      post "activate_card" => "credit_card#activate_card"
      get 'activate' => 'credit_card#activate'

      post 'frontend_version' => 'frontend_version#persist_version'
      post 'frontend_version/invalidate' => 'frontend_version#invalidate_version'
      get 'frontend_version' => 'frontend_version#list_versions'
      get 'frontend_version/:application_uuid' => 'frontend_version#app_version'

      # Alias for frontend_version/:application_uuid that can be exposed externally.
      get 'ext_frontend_version/:application_uuid' => 'frontend_version#app_version'
    end

    match "*path(.:format)" => "application#not_found", as: "not_found", via: :all
  end
end
