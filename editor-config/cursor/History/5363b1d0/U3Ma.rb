require 'socket'
require 'json'
require 'oj'
require 'avant/tenant_definitions'
require 'avant/env/customer_sso'
require 'posix-spawn'
require 'rails'

# There should be NO calls to ActiveRecord objects in this file!, if you are going to do this, put it in 'avant/env_active_record_references'

module Avant
  module Env
    extend POSIX::Spawn

    # this is here for documentation purposes. it turns out (in ruby 2.6/2.7 at
    # least) that it's slightly faster to put a regex directly in a `match?()`
    # call instead of using a constant. go figure.
    BOOLEAN_ENV_REGEX = /(true|1|yes)/i.freeze

    # Takes a string ENV key and returns a true or false boolean value based on
    # the value of the ENV variable.
    # The target ENV variable MUST be defined and its value MUST match
    # BOOLEAN_ENV_REGEX in order for this method to return true.
    def self.env_to_boolean(env)
      !!ENV[env]&.match?(/true|1|yes/i)
    end
    singleton_class.send(:alias_method, :is_set?, :env_to_boolean)

    def self.paths_to_regex(paths, trailing_matcher: "?")
      /#{paths.map { |fp| Regexp.quote(fp) }.join("|")}#{trailing_matcher}/
    end

    def self.validate_workflow_redirects?; !Rails.env.test?; end

    def self.integral(env)
      raw = get_env(env)
      /\A\d+\z/.match?(raw) ? raw.to_i : yield
    end

    def self.get_env(env)
      ENV[env]
    end

    def self.get_env_base64(env)
      return if ENV[env].nil?

      Base64.strict_decode64(ENV[env])
    end

    def self.local_development?
      return true if Rails.env.development?

      Rails.env.test?
    end

    def self.g2_enable_hard_failures?
      env_to_boolean('G2_ENABLE_HARD_FAILURES')
    end

    def self.point_of_sale_token_expiration_seconds
      ENV['POINT_OF_SALE_TOKEN_EXPIRATION_SECONDS']
    end

    def self.account_opening_point_of_sale_enabled?
      env_to_boolean('ACCOUNT_OPENING_POINT_OF_SALE_ENABLED')
    end

    def self.disable_cim_data_source_mocks?
      env_to_boolean('DISABLE_CIM_DATA_SOURCE_MOCKS')
    end

    def self.multi_product_enabled?
      env_to_boolean('MULTI_PRODUCT_ENABLED')
    end

    def self.cc_g2_enabled?
      env_to_boolean('CC_G2_ENABLED')
    end

    def self.decision_pending_stage_enabled?
      env_to_boolean('ENABLE_DECISION_PENDING_STAGE')
    end

    def self.dormant_auth_page_enabled?
      env_to_boolean('DORMANT_AUTH_ENABLED')
    end

    def self.terms_decision_enabled?
      env_to_boolean('TERMS_DECISION_ENABLED')
    end

    def self.disable_legacy_pricing_framework_issuance?
      env_to_boolean('DISABLE_ISSUANCE_LEGACY_PRICING_FRAMEWORK')
    end

    def self.disable_risk_segment_issuance?
      env_to_boolean('DISABLE_ISSUANCE')
    end

    def self.risk_segment_fix_date
      ENV['RISK_SEGMENT_FIX_DATE']
    end

    def self.sidekiq_schedule_enabled?
      env_to_boolean('SIDEKIQ_SCHEDULE_ENABLED')
    end

    def self.sidekiq_logging_enabled?
      env_to_boolean('SIDEKIQ_LOGGING_ENABLED')
    end

    def self.chat_logging_enabled?
      return true unless ENV.key?("CHAT_LOGGING_ENABLED")

      env_to_boolean("CHAT_LOGGING_ENABLED")
    end

    def self.alert_on_issuance_error?
      env_to_boolean('ALERT_ON_ISSUANCE_ERROR')
    end

    def self.enable_risk_segmentation_rollout?
      env_to_boolean('ENABLE_RISK_SEGMENT_PRICING_FRAMEWORK')
    end

    def self.rake?
      defined?(Rake) && Rake.application.top_level_tasks.present?
    end

    def self.db_migrate?
      rake? && Rake.application.top_level_tasks.include?('db:migrate')
    end

    def self.database_rake?
      rake? && Rake.application.top_level_tasks.any? { |task| task.start_with?('db:') }
    end

    def self.knockoff_replicas
      ENV['KNOCKOFF_REPLICA_ENVS']
    end

    def self.ocr_enabled?
      Avant::Env.env_to_boolean('OCR_ENABLED')
    end

    def self.ocr_environment
      Rails.env
    end

    def self.ocr_endpoint
      ENV['OCR_ENDPOINT']
    end

    def self.ocr_username
      ENV['OCR_USERNAME']
    end

    def self.submit_support_ticket_v2_active?
      env_to_boolean('IS_SUBMIT_SUPPORT_TICKET_V2_ACTIVE')
    end

    def self.ocr_password
      ENV['OCR_PASSWORD']
    end

    def self.the_work_number_user_id
      ENV['THE_WORK_NUMBER_USER_ID']
    end

    def self.the_work_number_user_id_gold
      ENV['THE_WORK_NUMBER_USER_ID_GOLD']
    end

    def self.twn_verification_url
      ENV['TWN_VERIFICATION_URL']
    end

    def self.the_work_number_password
      ENV['THE_WORK_NUMBER_USER_PASSWORD']
    end

    def self.the_work_number_reseller_user_id
      ENV['THE_WORK_NUMBER_RESELLER_USER_ID']
    end

    def self.the_work_number_reseller_password
      ENV['THE_WORK_NUMBER_RESELLER_PASSWORD']
    end

    def self.override_twn_mock_service
      env_to_boolean('OVERRIDE_TWN_MOCK_SERVICE')
    end

    def self.twn_multiplier
      (ENV['TWN_MULTIPLIER'] || 1).to_f
    end

    def self.servicing_api_public_key
      ENV['SERVICING_API_PUBLIC_KEY']
    end

    # This variable is used to call TransUnion, so the
    # builling is separated from the builling of AO
    def self.servicing_member_id
      ENV['SERVICING_MEMBER_ID']
    end

    def self.servicing_api_decrypt_secret_key
      @servicing_api_decrypt_secret_key ||= if (key = ENV['SERVICING_API_DECRYPT_SECRET_KEY']) # assignment intentional
        Base64.decode64(key)
      end
    end

    def self.servicing_api_decrypt_context
      return unless (key = servicing_api_decrypt_secret_key)

      @servicing_api_decrypt_context ||= ::GPGME::Ctx.new.tap do |ctx|
        ctx.import_keys(::GPGME::Data.new(key))
      end
    end

    def self.identity_theft_email
      ENV['IDENTITY_THEFT_EMAIL']
    end

    def self.reject_all_leads?
      env_to_boolean('REJECT_ALL_LEADS')
    end

    def self.initial_borrow_amount_adjustment
      if ENV['INITIAL_BORROW_AMOUNT_ADJUSTMENT']
        ENV['INITIAL_BORROW_AMOUNT_ADJUSTMENT'].to_f
      else
        1.0
      end
    end

    def self.syncronous_easy_application_timeout
      ENV['SYNC_EASY_APPLICATION_TIMEOUT']&.to_i&.seconds || 28.seconds
    end

    def self.syncronous_verifications_timeout
      ENV['SYNC_VERIFICATIONS_TIMEOUT']&.to_i&.seconds || 20.seconds
    end

    def self.synchronous_plaid_report_timeout
      ENV['SYNC_PLAID_REPORT_TIMEOUT']&.to_i&.seconds || 5.seconds
    end

    def self.in_branch_sms_disabled?
      env_to_boolean('IN_BRANCH_SMS_DISABLED')
    end

    # this method checks if on production server, defaults to true if Rails.env.production? and if environment doesn't
    # contain STAGING_ENABLED env var
    def self.acts_as_prod?
      return false unless Rails.env.production? || Rails.env.test? # for tests to act like production
      return false if integration_environment?

      true
    end

    def self.url_helper_hash
      if heroku_env?
        {
          host: heroku_host,
          protocol: 'https'
        }
      else
        {
          host:  ENV['MAILER_HOST'] || 'avant.com',
          protocol: ENV['MAILER_PROTOCOL'] || 'https'
        }
      end
    end

    def self.production_env?
      Rails.env.production? && !env_to_boolean('STAGING_ENABLED')
    end

    def self.private_integration?
      Avant::Env.integration_environment? && env_to_boolean('PRIVATE_INTEGRATION')
    end

    def self.heroku_env?
      env_to_boolean('HEROKU_ENABLED')
    end

    def self.heroku_staging?
      heroku_env? && integration_environment?
    end

    def self.heroku_app_name
      return unless heroku_env?
      ENV['HEROKU_DNS_FORMATION_NAME'].split('.')[1]
    end

    def self.heroku_host
      return unless heroku_env?
      "#{heroku_app_name}.herokuapp.com"
    end

    def self.heroku_url
      return unless heroku_env?
      "https://#{heroku_host}"
    end

    def self.integration_environment?
      env_to_boolean('STAGING_ENABLED')
    end

    def self.public_integration?
      Avant::Env.integration_environment? && env_to_boolean('PUBLIC_INTEGRATION')
    end

    def self.garden?
      env_to_boolean('AVANT_GARDEN')
    end

    def self.yodlee_enabled?
      env_to_boolean('YODLEE_ENABLED')
    end

    def self.underwriting_enabled?
      env_to_boolean('UNDERWRITING_ENABLED')
    end

    def self.pagerduty_enabled?
      production_env? && env_to_boolean('PAGERDUTY_ENABLED')
    end

    def self.geoip_redirection?
      env_to_boolean('ENABLE_GEOIP_REDIRECTION')
    end

    def self.gtm_enabled?
      return env_to_boolean('GTM_ENABLED') if ENV['GTM_ENABLED']

      Rails.env.production?
    end

    ##############################################
    # These are temp env vars to allow for us to temporarily
    # disable certain emails per https://amount.atlassian.net/browse/VER-4021
    # we should remove these methods and the corresponding var entries
    # in vault once we get the green light to turn these back

    def self.skip_loan_stale_email?
      env_to_boolean('SKIP_LOAN_STALE_EMAIL')
    end

    def self.skip_incomplete_tasks_reminder_email?
      env_to_boolean('SKIP_INCOMPLETE_TASKS_REMINDER_EMAIL')
    end
    ##############################################

    def self.env_string
      if production_env?
        TenantDefinitions::PRODUCTION_ENV_STRING
      elsif Rails.env.development?
        TenantDefinitions::DEVELOPMENT_ENV_STRING
      elsif Rails.env.test?
        TenantDefinitions::TEST_ENV_STRING
      else
        unless integration_environment?
          warn('STAGING_ENABLED ENV var is NOT set for this INTEGRATION ENVIRONMENT')
        end
        TenantDefinitions::INTEGRATION_ENV_STRING
      end
    end

    def self.gtm_env
      if env_string == TenantDefinitions::TEST_ENV_STRING
        TenantDefinitions::DEVELOPMENT_ENV_STRING
      else
        env_string
      end
    end

    def self.mock_user_permissions?
      env_to_boolean('MOCK_USER_PERMISSIONS')
    end

    def self.email_copy_to_aws?
      env_to_boolean('COPY_EMAIL_TO_AWS')
    end

    def self.hide_agi_if_already_filled?
      env_to_boolean('HIDE_AGI_IF_ALREADY_FILLED?')
    end

    def self.synchronous_emails?
      env_to_boolean('SYNCHRONOUS_EMAILS')
    end

    def self.email_whitelist_regex
      return nil if ENV['EMAIL_WHITELIST_REGEX'].blank?

      Regexp.new(ENV['EMAIL_WHITELIST_REGEX'])
    end

    def self.ccpa_expunge_live?
      env_to_boolean('CCPA_EXPUNGE_LIVE')
    end

    def self.application_logic_init_enabled?
      env_to_boolean('APPLICATION_LOGIC_INIT_ENABLED')
    end

    def self.avant_modeling_api_enabled?
      env_to_boolean('AVANT_MODELING_API_ENABLED')
    end

    def self.smarty_streets_enabled
      env_to_boolean('SMARTY_STREETS_ENABLED')
    end

    def self.smarty_streets_backend_enabled
      env_to_boolean('SMARTY_STREETS_BACKEND_ENABLED')
    end

    def self.override_cim_scenarios?
      env_to_boolean('OVERRIDE_CIM_SCENARIOS')
    end

    def self.avant_config_url
      ENV['AVANT_CONFIG_URL']
    end

    def self.avant_config_api_token
      ENV['AVANT_CONFIG_API_TOKEN']
    end

    def self.coverband_password
      # There must be a password or auth will be disabled for coverband- so default password to this one.
      ENV['COVERBAND_PASSWORD'] || 'super-secret'
    end

    def self.smarty_streets_client_auth_id
      ENV['SMARTY_STREETS_CLIENT_AUTH_ID']
    end

    def self.smarty_streets_service_auth_id
      ENV['SMARTY_STREETS_SERVICE_AUTH_ID']
    end

    def self.smarty_streets_auth_token
      ENV['SMARTY_STREETS_AUTH_TOKEN']
    end

    def self.jitbit_username
      ENV['JITBIT_USER']
    end

    def self.jitbit_password
      ENV['JITBIT_PASSWORD']
    end

    def self.jira_user_email
      ENV['JIRA_USER_EMAIL']
    end

    def self.jira_user_token
      ENV['JIRA_USER_TOKEN']
    end

    def self.batch_sourcing_enabled?
      env_to_boolean('ANALYTICS_BATCH_SOURCING_ENABLED')
    end

    def self.product_rating_enabled?
      env_to_boolean('PRODUCT_RATING_ENABLED')
    end

    def self.rapleaf_enabled?
      env_to_boolean('RAPLEAF_ACTIVE_FLAG') || !Avant::Env.acts_as_prod?
    end

    def self.send_ao_orders_to_merchant_portal?
      env_to_boolean('SEND_AO_ORDERS_TO_MERCHANT_PORTAL')
    end

    def self.send_am_orders_to_merchant_portal?
      env_to_boolean('SEND_AM_ORDERS_TO_MERCHANT_PORTAL')
    end

    def self.merchant_portal_api_token
      ENV['MERCHANT_PORTAL_API_TOKEN']
    end

    def self.merchant_service_api_token
      ENV['MERCHANT_SERVICE_API_TOKEN']
    end

    def self.merchant_portal_client_token
      ENV['MERCHANT_PORTAL_CLIENT_TOKEN']
    end

    def self.merchant_portal_orders_url
      ENV['MERCHANT_PORTAL_ORDERS_URL']
    end

    def self.force_synchronous_pubsub?
      env_to_boolean('FORCE_SYNCHRONOUS_PUBSUB')
    end

    def self.phone_verification_waiting_seconds
      ENV['PHONE_VERIFICATION_WAITING_SECONDS'].to_i
    end

    def self.always_allow_manual_payment_file_send?
      env_to_boolean("ALWAYS_ALLOW_MANUAL_PAYMENT_FILE_SEND")
    end

    module CardmemberAgreement
      def self.updated_arbitration_cutoff_date
        ENV.fetch('UPDATED_ARBITRATION_CUTOFF_DATE')&.to_date
      end
    end

    module Nelnet
      def self.url
        ENV.fetch('NELNET_URL')
      end

      def self.user_name
        ENV.fetch('NELNET_USERNAME')
      end

      def self.password
        ENV.fetch('NELNET_PASSWORD')
      end

      def self.user_pool_id
        ENV.fetch('NELNET_USER_POOL_ID')
      end

      def self.app_client_id
        ENV.fetch('NELNET_APP_CLIENT_ID')
      end

      def self.lender_id
        ENV.fetch('NELNET_LENDER_ID')
      end

      def self.loan_program_id
        ENV.fetch('NELNET_LOAN_PROGRAM_ID')
      end

      def self.investor_id
        ENV.fetch('NELNET_INVESTOR_ID')
      end
    end

    module Mitek
      def self.username
        ENV['MITEK_USERNAME']
      end

      def self.password
        ENV['MITEK_PASSWORD']
      end

      def self.auth_url
        ENV['MITEK_AUTH_URL']
      end

      def self.url
        ENV['MITEK_URL']
      end
    end

    def self.run_fraud_risk_model?
      env_to_boolean('RUN_FRAUD_MODEL')
    end

    def self.fraud_decision_completeness_check_enabled?
      env_to_boolean('FRAUD_DECISION_COMPLETENESS_CHECK_ENABLED') || Rails.env.test?
    end

    def self.block_issuance_if_missing_reports?
      env_to_boolean('BLOCK_PREISSUANCE_IF_MISSING_REPORTS') || production_env?
    end

    def self.disable_noaa_lock
      env_to_boolean('DISABLE_NOAA_LOCK')
    end

    def self.high_fico_model_enabled
      var = 'HIGH_FICO_MODEL_ENABLED'
      env_to_boolean(var)
    end

    def self.high_fico_experiment_enabled
      var = 'HIGH_FICO_EXPERIMENT_ENABLED'
      (begin
         Time.zone.parse(get_env(var))
       rescue StandardError
         false
       end) || env_to_boolean(var)
    end

    def self.a2_experiment_enabled
      var = 'A2_EXPERIMENT_ENABLED'
      (begin
         Time.zone.parse(get_env(var))
       rescue StandardError
         false
       end) || env_to_boolean(var)
    end

    def self.experiments_enabled
      # Default to legacy PRICING_EXPERIMENT_ENABLED unless EXPERIMENTS_ENABLED is set
      return env_to_boolean('PRICING_EXPERIMENT_ENABLED') unless ENV.key?('EXPERIMENTS_ENABLED')

      env_to_boolean('EXPERIMENTS_ENABLED')
    end

    def self.fact_cache_enabled?
      !env_to_boolean('FACT_CACHE_DISABLED')
    end

    def self.fact_errors_enabled?
      !env_to_boolean('FACT_ERRORS_DISABLED')
    end

    def self.fail_whale_enabled?
      !env_to_boolean('FAIL_WHALE_DISABLED')
    end

    def self.auto_approval_enabled?
      env_to_boolean('AUTO_APPROVAL_ENABLED')
    end

    def self.credit_card_auto_approval_enabled?
      env_to_boolean('CREDIT_CARD_AUTO_APPROVAL_ENABLED')
    end

    def self.auto_rejection_enabled?
      env_to_boolean('AUTO_REJECTION_ENABLED')
    end

    def self.reject_review_enabled?
      env_to_boolean('REJECT_REVIEW_ENABLED') || Rails.env.test?
    end

    def self.prime_tier_queue_enabled?
      env_to_boolean('PRIME_TIER_QUEUE_ENABLED')
    end

    def self.send_contract_worker_enabled?
      env_to_boolean('SEND_CONTRACT_WORKER_ENABLED')
    end

    def self.identity_match_reattempt_enabled?
      env_to_boolean('IDENTITY_MATCH_REATTEMPT_ENABLED')
    end

    def self.legacy_applications_date
      var = 'LEGACY_APPLICATIONS_DATE'
      legacy_date = get_env(var)
      legacy_date ? Time.zone.parse(legacy_date) : nil
    end

    def self.r_server_scoring_timeout
      integral('CREDIT_MODEL_SERVICE_MAX_TIMEOUT') { 4 }
    end

    def self.r_server_sidekiq_scoring_timeout
      integral('CREDIT_MODEL_SERVICE_SIDEKIQ_MAX_TIMEOUT') do
        r_server_scoring_timeout
      end
    end

    def self.credit_model_legacy_v1_cutoff
      ENV['CREDIT_MODEL_LEGACY_V1_CUTOFF'].to_i
    end

    def self.read_only_modeling_cache?
      env_to_boolean('READ_ONLY_MODELING_CACHE')
    end

    def self.model_score_mirroring_enabled?
      env_to_boolean('MODEL_SCORE_MIRRORING_ENABLED')
    end

    def self.hostname
      Socket.gethostname
    end

    def self.lead_api_token_enforced?
      env_to_boolean('LEAD_API_TOKEN_ENFORCED')
    end

    def self.lead_proxy_url
      ENV['QUOTAGUARDSTATIC_URL']
    end

    def self.lending_tree_auto_post_url
      ENV['LENDING_TREE_AUTO_POST_URL']
    end

    def self.my_auto_loan_base_url
      ENV['MY_AUTO_LOAN_BASE_URL']
    end

    def self.my_auto_loan_active?
      env_to_boolean('MY_AUTO_LOAN_ACTIVE')
    end

    def self.enable_application_policy_locking?
      env_to_boolean('ENABLE_APPLICATION_POLICY_LOCKING')
    end

    def self.dms_endpoint
      ENV['DMS_ENDPOINT']
    end

    def self.dms_client_id
      ENV['DMS_CLIENT_ID']
    end

    def self.dms_user_id
      ENV['DMS_USER_ID']
    end

    def self.dms_password
      ENV['DMS_PASSWORD']
    end

    def self.dms_account
      ENV['DMS_ACCOUNT']
    end

    def self.dms_account_password
      ENV['DMS_ACCOUNT_PASSWORD']
    end

    def self.finscan_user
      ENV['FINSCAN_USER']
    end

    def self.finscan_pass
      ENV['FINSCAN_PASS']
    end

    def self.factor_trust_enabled?
      !!ENV['FACTORTRUST_URL']
    end

    def self.id_analytics_olna_enabled?
      !!ENV['ID_ANALYTICS_OLNA_ENABLED']
    end

    def self.pull_sentilink_application_risk_report_enabled?
      env_to_boolean('PULL_SENTILINK_APPLICATION_RISK_REPORT_ENABLED')
    end

    def self.paid_in_full_letters_enabled?
      env_to_boolean('PAID_IN_FULL_LETTERS_ENABLED')
    end

    # returns whether or not to enable the autofill-with-generated-data buttons during the application process
    def self.autofill_enabled?
      Rails.env.development? || env_to_boolean('AUTOFILL_ENABLED')
    end

    def self.jumio_merchant_api_key
      ENV['JUMIO_MERCHANT_API_KEY']
    end

    def self.jumio_active_api_secret
      ENV['JUMIO_ACTIVE_API_SECRET']
    end

    def self.password_velocity_checks_enabled?
      env_to_boolean('PASSWORD_VELOCITY_CHECKS_ENABLED')
    end

    def self.password_velocity_salt
      ENV['PASSWORD_VELOCITY_SALT']
    end

    def self.fraud_app_base_uri
      ENV['FRAUD_APP_BASE_URI']
    end

    def self.fraud_app_basic_auth_username
      ENV['FRAUD_APP_BASIC_AUTH_USERNAME']
    end

    def self.fraud_app_basic_auth_password
      ENV['FRAUD_APP_BASIC_AUTH_PASSWORD']
    end

    def self.enable_emailage
      env_to_boolean('ENABLE_EMAILAGE')
    end

    def self.enable_telesign
      env_to_boolean('ENABLE_TELESIGN')
    end

    def self.visitor_tracking_enabled?
      env_to_boolean('VISITOR_TRACKING_ENABLED')
    end

    def self.session_store_cookie_domain
      ENV['SESSION_STORE_COOKIE_DOMAIN']
    end

    # Note these || account values are production credentials.
    # At time of build, Emailage sandbox signup was down. 10 cents/pull though, not bad.
    def self.emailage_account_sid
      ENV['EMAILAGE_ACCOUNT_SID'] || 'dummycredreplacewithtestapikey'
    end

    def self.emailage_auth_token
      ENV['EMAILAGE_AUTH_TOKEN'] || 'dummycredreplacewithtestapikey'
    end

    def self.emailage_base_uri
      # Uncomment when you have actual sandbox credentials up there.
      # Rails.env.production? ? 'https://api.emailage.com/EmailAgeValidator/' : 'https://sandbox.emailage.com/EmailAgeValidator/'
      'https://api.emailage.com/'
    end

    def self.rails_locale
      ENV['RAILS_LOCALE']
    end

    def self.iovation_subscriber_id
      ENV['IOVATION_SUBSCRIBER_ID']
    end

    def self.iovation_endpoint
      ENV['IOVATION_ENDPOINT']
    end

    def self.iovation_debug
      ENV['IOVATION_DEBUG']
    end

    def self.iovation_subscriber_account
      ENV['IOVATION_SUBSCRIBER_ACCOUNT']
    end

    def self.iovation_subscriber_passcode
      ENV['IOVATION_SUBSCRIBER_PASSCODE']
    end

    def self.emailage_customer_identifier
      ENV['EMAILAGE_CUSTOMER_IDENTIFIER']
    end

    def self.emailage_partner_id
      ENV['EMAILAGE_PARTNER_ID']
    end

    def self.emailage_pos_customer_identifier
      ENV['EMAILAGE_POS_CUSTOMER_IDENTIFIER']
    end

    def self.emailage_pos_partner_id
      ENV['EMAILAGE_POS_PARTNER_ID']
    end

    def self.kba_account_name
      ENV['KBA_ACCOUNT_NAME']
    end

    def self.pos_kba_account_name
      ENV['POS_KBA_ACCOUNT_NAME']
    end

    def self.kba_wsdl_url
      ENV['KBA_WSDL_URL']
    end

    def self.kba_username
      ENV['KBA_USERNAME']
    end

    def self.kba_password
      ENV['KBA_PASSWORD']
    end

    def self.telesign_api_key
      ENV['TELESIGN_API_KEY'] || 'dummycredreplacewithtestapikey'
    end

    def self.telesign_api_uri
      ENV['TELESIGN_API_URI'] || 'https://rest-api.telesign.com/'
    end

    def self.telesign_customer_id
      ENV['TELESIGN_CUSTOMER_ID'] || 'dummycredreplacewithtestapikey'
    end

    def self.mock_telesign_mfa
      env_to_boolean('MOCK_TELESIGN_MFA')
    end

    def self.proximo_url
      ENV['PROXIMO_URL']
    end

    def self.neustar_service_id
      ENV['NEUSTAR_SERVICE_ID']
    end

    def self.neustar_username
      ENV['NEUSTAR_USERNAME']
    end

    def self.neustar_url
      ENV.fetch('NEUSTAR_URL')
    end

    def self.neustar_password
      ENV['NEUSTAR_PASSWORD']
    end

    def self.neustar_savon_logging_off
      ENV['NEUSTAR_SAVON_LOGGING_OFF']
    end

    def self.rapleaf_api_key
      ENV['RAPLEAF_API_KEY']
    end

    def self.postal_methods_api_key
      ENV['POSTAL_METHODS_API_KEY'] || 'postal_methods_api_key'
    end

    def self.enable_sentry_prod_debug?
      env_to_boolean('SENTRY_DEBUG_ENABLED')
    end


    def self.giact_enabled
      env_to_boolean('GIACT_ENABLED')
    end

    # ENV['BIRDSEYE_URL'] = https://birdseye.internal.amount.com/api/apps/basic for avant basic
    def self.birdseye_url
      ENV['BIRDSEYE_URL']
    end

    def self.customer_motivators_sftp_address
      ENV['CUSTOMER_MOTIVATORS_SFTP_ADDRESS']
    end

    def self.customer_motivators_sftp_username
      ENV['CUSTOMER_MOTIVATORS_SFTP_USERNAME']
    end

    def self.customer_motivators_sftp_password
      ENV['CUSTOMER_MOTIVATORS_SFTP_PASSWORD']
    end

    def self.bmo_ftp_key_passphrase
      ENV['BMO_FTP_KEY_PASSPHRASE']
    end

    def self.cibc_sftp_password
      ENV['CIBC_SFTP_PASSWORD']
    end

    def self.pusher_enabled?
      !!ENV['PUSHER_ENABLED']
    end

    def self.enable_pusher!
      ENV['PUSHER_ENABLED'] = 'true'
    end

    def self.pusher_url
      ENV['PUSHER_URL']
    end

    def self.pusher_app_id
      ENV['PUSHER_APP_ID']
    end

    def self.pusher_app_key
      ENV['PUSHER_APP_KEY']
    end

    def self.pusher_app_secret
      ENV['PUSHER_APP_SECRET']
    end

    def self.telco_api_key
      ENV['TELCO_API_KEY']
    end

    def self.telco_api_allowed_ip
      ENV['TELCO_API_ALLOWED_IP']
    end

    # can split with |
    def self.first_data_allowed_ips
      ENV['FIRST_DATA_ALLOWED_IPS']
    end

    def self.servicing_api_allowed_ips
      ENV['SERVICING_API_ALLOWED_IPS']
    end

    def self.servicing_api_enabled?
      env_to_boolean('SERVICING_API_ENABLED')
    end

    def self.cim_api_enabled?
      env_to_boolean('CIM_API_ENABLED')
    end

    def self.make_payment_ivr_enabled?
      env_to_boolean('MAKE_PAYMENT_IVR_ENABLED')
    end

    def self.quote_payoff_ivr_enabled?
      env_to_boolean('QUOTE_PAYOFF_IVR_ENABLED')
    end

    def self.alltran_transfer_ivr_enabled?
      env_to_boolean('ALLTRAN_TRANSFER_IVR_ENABLED')
    end

    def self.teleperformance_transfer_ivr_enabled?
      env_to_boolean('TELEPERFORMANCE_TRANSFER_IVR_ENABLED')
    end

    def self.heap_token
      ENV['HEAP_TOKEN']
    end

    # @deprecated TODO: delete `administration_fees_enabled?`, it is only used in deprecated tests, remove from vault too
    def self.administration_fees_enabled?
      env_to_boolean('ADMINISTRATION_FEES_ENABLED')
    end

    def self.ultra_short_term_credit_model_score_enabled?
      env_to_boolean('ULTRA_SHORT_TERM_CREDIT_MODEL_SCORE_ENABLED')
    end

    def self.credit_karma_welcome_email_enabled?
      env_to_boolean('CREDIT_KARMA_WELCOME_EMAIL_ENABLED')
    end

    def self.credit_card_scheduled_jobs_enabled?
      env_to_boolean('CREDIT_CARD_SCHEDULED_JOBS_ENABLED')
    end

    def self.credit_card_decisioning_enabled?
      env_to_boolean('CREDIT_CARD_DECISIONING_ENABLED')
    end

    def self.credit_card_payments_enabled?
      env_to_boolean('CREDIT_CARD_PAYMENTS_ENABLED')
    end

    def self.credit_card_account_cache_disabled?
      env_to_boolean('CREDIT_CARD_ACCOUNT_CACHE_DISABLED')
    end

    def self.credit_card_s3_bucket
      ENV['CREDIT_CARD_S3_BUCKET']
    end

    def self.credit_card_s3_region
      ENV['CREDIT_CARD_S3_REGION']
    end

    def self.credit_card_s3_access_id
      ENV['CREDIT_CARD_S3_ACCESS_ID']
    end

    def self.credit_card_s3_secret_key
      ENV['CREDIT_CARD_S3_SECRET_KEY']
    end

    def self.credit_card_retry_sleep_between_retries?
      env_to_boolean("CREDIT_CARD_RETRY_SLEEP_BETWEEN_RETRIES")
    end

    def self.credit_card_retry_sleep_interval
      @credit_card_retry_sleep_interval ||= ENV.fetch("CREDIT_CARD_RETRY_SLEEP_INTERVAL", "0.33").to_f
    end

    def self.credit_card_retry_count
      @credit_card_retry_count ||= ENV.fetch("CREDIT_CARD_RETRY_COUNT", "3").to_i
    end

    def self.ccapi_timeouts
      return {} unless ENV['CCAPI_TIMEOUTS']

      Oj.load(Base64.strict_decode64(ENV['CCAPI_TIMEOUTS'])).symbolize_keys
    rescue StandardError
      {}
    end

    def self.converge_test_mode
      !!ENV['CONVERGE_TEST_MODE']
    end

    def self.spring_labs_url
      ENV['SPRING_LABS_URL']
    end

    def self.spring_labs_api_key
      ENV['SPRING_LABS_API_KEY']
    end

    def self.dalli_value_max_bytes
      # default to 25 MB, don't allow lower than 1 MB
      [(ENV['DALLI_VALUE_MAX_BYTES'].to_i || 25.megabytes), 1.megabyte].max
    end

    def self.whitepages_api_key
      ENV['WHITEPAGES_API_KEY']
    end

    def self.whitepages_url
      ENV['WHITEPAGES_URL']
    end

    def self.whitepages_enabled?
      env_to_boolean('WHITEPAGES_ENABLED')
    end

    def self.account_number
      ENV['AVANT_BANK_ACCOUNT_NUMBER']
    end

    def self.routing_number
      ENV['AVANT_BANK_ROUTING_NUMBER']
    end

    def self.plaid_env
      ENV['PLAID_ENV']
    end

    def self.plaid_client_id
      ENV['PLAID_CLIENT_ID']
    end

    def self.plaid_client_name
      ENV['PLAID_CLIENT_NAME']
    end

    def self.plaid_language
      ENV['PLAID_LANGUAGE']
    end

    def self.plaid_public_key
      ENV['PLAID_PUBLIC_KEY']
    end

    def self.plaid_secret
      ENV['PLAID_SECRET']
    end

    def self.plaid_products
      (ENV['PLAID_PRODUCTS'] || '').split(',')
    end

    def self.plaid_countries
      (ENV['PLAID_COUNTRY_CODES'] || '').split(',')
    end

    def self.plaid_webhook_url
      ENV['PLAID_WEBHOOK_URL']
    end

    def self.plaid_days_history
      ENV['PLAID_DAYS_HISTORY']&.to_i || 730
    end

    def self.avant_credit_card_bcc_email_address
      ENV['AVANT_CREDIT_CARD_BCC_EMAIL_ADDRESS']
    end

    def self.base_url_host
      ENV['BASE_URL_HOST']
    end

    def self.fallback_base_url
      if self.base_url_host.present?
        host = self.base_url_host
        return host.start_with?('https://') ? host : "https://#{host}"
      end
      return TenantConfig.company.clickable_url                    if self.production_env?
      return "https://#{ENV['SENTRY_ENVIRONMENT']}.global.avant.com" if self.private_integration?
      return "https://#{ENV['SENTRY_ENVIRONMENT']}.avant-test.com" if self.public_integration?
      'http://localhost:5001' if !self.production_env?
    end

    def self.regions_credit_scorer_url
      ENV['REGIONS_CREDIT_SCORER_URL']
    end

    def self.regions_decline_path_enabled?
      env_to_boolean('REGIONS_DECLINE_PATH_ENABLED')
    end

    # URL to endpoint to retrieve an access token for Regions' Customer API
    #
    # @return [String] the url of the resource
    def self.regions_access_token_url
      ENV['REGIONS_ACCESS_URL']
    end

    def self.regions_api_url
      ENV['REGIONS_API_URL']
    end

    def self.regions_api_login
      ENV['REGIONS_API_LOGIN']
    end

    def self.regions_api_password
      ENV['REGIONS_API_PASSWORD']
    end

    def self.regions_customer_api_enabled?
      env_to_boolean('ENABLE_REGIONS_CUSTOMER_API') # standardize naming convention
    end

    def self.avant_api_enabled?
      env_to_boolean('AVANT_API_ENABLED')
    end

    def self.proxy_url
      ENV['PROXIMO_URL']
    end

    def self.forward_proxy_url
      ENV['FORWARD_PROXY_URL']
    end

    # Begin Experian Authentication variables
    # They default to the test environment credentials

    def self.experian_config
      @experian_config ||= YAML.load_file(File.join(Rails.root, 'config', 'experian.yml'))
    end

    def self.experian_vin_gateway_id
      if Rails.env.production?
        ENV['EXPERIAN_VIN_GATEWAY_ID']
      else
        experian_config['vin_gateway']['test']['id']
      end
    end

    def self.experian_vin_gateway_password
      if Rails.env.production?
        ENV['EXPERIAN_VIN_GATEWAY_PASSWORD']
      else
        experian_config['vin_gateway']['test']['password']
      end
    end

    # End Experian Authentication variables

    def self.kba_grade_return_enabled
      env_to_boolean('KBA_GRADE_RETURN_ENABLED')
    end

    def self.enable_prod_kba?
      # Beware, adventurous dev. Enabling this env var will make your
      # development environment hit the external API for KBA
      acts_as_prod? || env_to_boolean('ENABLE_PRODUCTION_KBA')
    end

    def self.robots_enabled?
      env_to_boolean('ROBOTS_ENABLED')
    end

    def self.api_webview_host
      ENV['API_WEBVIEW_HOST'] || 'https://avant.com'
    end

    def self.skip_validating_routing_number_in_bank_details?
      env_to_boolean('SKIP_VALIDATING_ROUTING_NUMBER_IN_BANK_DETAILS')
    end

    def self.preserve_yodlee_data_provider_login_form?
      env_to_boolean('PRESERVE_YODLEE_DATA_PROVIDER_LOGIN_FORM')
    end

    def self.transunion_password
      ENV.fetch('TRANSUNION_PASSWORD', 'avant888')
    end

    def self.transunion_url
      return ENV['TRANSUNION_URL'] if ENV['TRANSUNION_URL']
      return 'https://netaccess.not_real_testing.com' unless Avant::Env.production_env?
    end

    def self.transunion_cert_file_path
      ENV.fetch('TRANSUNION_CERT_FILE', 'mock_service_fake_pem/MOCK.p12')
    end

    def self.declinable_tu_level_four_error_codes
      ENV.fetch('DECLINABLE_TU_LEVEL_FOUR_ERROR_CODES', '').split(',')
    end

    def self.kenshoo_username
      ENV['KENSHOO_UN']
    end

    def self.kenshoo_password
      ENV['KENSHOO_PW']
    end

    def self.scheduled_jobs_monitor_enabled?
      env_to_boolean('SCHEDULED_JOBS_MONITOR_ENABLED')
    end

    def self.api_logger_on?
      env_to_boolean('API_LOGGER_ON')
    end

    def self.lob_api_key
      ENV['LOB_API_KEY']
    end

    def self.onboarding_api_pos_enabled?
      env_to_boolean('ONBOARDING_API_POS_ENABLED')
    end

    def self.sentry_environment
      ENV['SENTRY_ENVIRONMENT'] || "avant"
    end

    def self.debug?
      env_to_boolean('LOG_DEBUG')
    end

    module Logger
      def self.enabled?
        Avant::Env.env_to_boolean('LOGGER_ENABLED')
      end

      def self.debug?
        ENV['LOGGER_DEBUG']
      end

      def self.aws_kinesis_firehose_stream
        ENV['LOGGER_AWS_KINESIS_FIREHOSE_STREAM']
      end

      def self.aws_region
        ENV['LOGGER_AWS_REGION']
      end

      def self.aws_access_key_id
        ENV['LOGGER_AWS_ACCESS_KEY_ID']
      end

      def self.aws_secret_access_key
        ENV['LOGGER_AWS_SECRET_ACCESS_KEY']
      end
    end

    def self.user_echo_api_key
      ENV['USER_ECHO_API_KEY']
    end

    def self.bartleby_endpoint
      ENV['BARTLEBY_ENDPOINT']
    end

    def self.bartleby_auth_token
      ENV['BARTLEBY_AUTH_TOKEN']
    end

    def self.enable_mock_services?
      env_to_boolean('ENABLE_MOCK_SERVICES')
    end

    def self.ignore_mock?(service_name)
      env_to_boolean("IGNORE_MOCK_#{service_name.to_s.upcase}")
    end

    def self.override_avant_card_mock_service?
      env_to_boolean('OVERRIDE_AVANT_CARD_MOCK_SERVICE')
    end

    def self.app_processing_qa_enabled?
      env_to_boolean('APP_PROCESSING_QA_ENABLED')
    end

    def self.loan_service_url
      ENV.fetch('LOAN_SERVICE_URL', 'http://loan-api:3000')
    end

    def self.loan_service_retry_count
      ENV.fetch('LOAN_SERVICE_RETRY_COUNT', '3').to_i
    end

    def self.loan_service_api_key
      ENV['LOAN_SERVICE_API_KEY']
    end

    def self.loan_service_publish_outbox_events
      env_to_boolean('LOAN_SERVICE_PUBLISH_OUTBOX_EVENTS')
    end

    def self.loan_service_event_publish_batch_size
      ENV.fetch('LOAN_SERVICE_EVENT_PUBLISH_BATCH_SIZE', '200').to_i
    end

    module CreditCardCore
      def self.enable_cc_core_payment_plan_cache_get?
        Avant::Env.env_to_boolean('ENABLE_CC_CORE_PAYMENT_PLAN_CACHE_GET')
      end

      def self.enable_cc_core_create_payment_plan?
        Avant::Env.env_to_boolean('ENABLE_CC_CORE_CREATE_PAYMENT_PLAN')
      end
    end

    def self.credit_card_api_endpoint
      ENV['CREDIT_CARD_API_ENDPOINT'] || ""
    end

    def self.debt_sale_portal_host_url
      ENV["DEBT_SALE_PORTAL_BASE_URL"] || "http://localhost:8000"
    end

    def self.debt_sale_portal_api_auth_token
      ENV["DEBT_SALE_PORTAL_API_AUTH_TOKEN"] || "devtoken"
    end

    def self.hardship_service_host_url
      ENV["HARDSHIP_SERVICE_BASE_URL"] || "http://localhost:8001"
    end

    def self.hardship_service_api_auth_token
      ENV["HARDSHIP_SERVICE_API_AUTH_TOKEN"] || "devtoken"
    end

    def self.credit_card_dashboard_root
      ENV['CREDIT_CARD_DASHBOARD_ROOT']
    end

    def self.credit_card_dashboard_rollout_percentage
      ENV['CC_DASH_ROLLOUT_PERCENTAGE']
    end

    def self.credit_card_shared_key
      ENV['CREDIT_CARD_SHARED_KEY']
    end

    def self.comm_hub_api_token
      ENV['COMM_HUB_API_TOKEN']
    end

    def self.event_sourcing_platform_api_endpoint
      ENV['EVENT_SOURCING_PLATFORM_API_ENDPOINT']
    end

    def self.outstanding_final_balance_adjustment_enabled?
      !!ENV['OUTSTANDING_FINAL_BALANCE_ADJUSTMENT_ENABLED']
    end

    def self.one_time_courtesy_v2_enabled
      env_to_boolean('ONE_TIME_COURTESY_V2_ENABLED')
    end

    def self.digital_identity_key
      if production_env?
        ENV['DIGITAL_IDENTITY_KEY']
      else
        'pass'
      end
    end

    def self.model_score_disabled?
      env_to_boolean('MODEL_SCORE_DISABLED')
    end

    def self.avant_admin_filter_by_ip?
      !env_to_boolean('AVANT_ADMIN_DISABLE_IP_FILTER')
    end

    def self.basic_public_url
      ENV['BASIC_PUBLIC_URL']
    end

    def self.crm_redirect_url
      return ENV['CRM_REDIRECT_URL'] if ENV['CRM_REDIRECT_URL']

      Rails.env.production? ? 'https://admin.avant.com' : 'http://localhost:4000'
    end

    def self.redirect_crm?
      env_to_boolean('REDIRECT_CRM')
    end

    def self.crm_shared_key
      ENV['CRM_SHARED_KEY'] || ''
    end

    def self.workflow_api
      ENV['WORKFLOW_API_URL']
    end

    def self.debug_graphql?
      env_to_boolean('DEBUG_GRAPHQL_ENABLED') && !production_env?
    end

    def self.customer_jwt_key
      ENV['CUSTOMER_JWT_KEY']
    end

    def self.payment_gateway_jwt_key
      ENV['PAYMENT_GATEWAY_JWT_KEY']
    end

    def self.payment_gateway_proxy
      ENV['PAYMENT_GATEWAY_PROXY']
    end

    def self.ip_dash_url
      ENV['IP_DASH_URL']
    end

    def self.frontend_login_url
      ENV['FRONTEND_LOGIN_URL']
    end

    def self.frontend_public_url
      ENV['FRONTEND_PUBLIC_URL'] || 'https://www.avant.com/public'
    end

    def self.customer_dash_url
      ENV['CUSTOMER_DASH_URL']
    end

    def self.customer_module_url
      ENV['CUSTOMER_MODULE_URL'] || 'http://localhost:5550'
    end

    def self.warning_banners
      ENV['WARNING_BANNERS']
    end

    def self.use_new_credit_card_dash
      env_to_boolean('USE_NEW_CREDIT_CARD_DASH')
    end

    # This env var controls whether or not there is a timeout for an application as well as the customer dashboard.
    def self.front_end_timeout_disabled
      env_to_boolean('FRONT_END_TIMEOUT_DISABLED')
    end

    def self.usb_sterling_sftp_enabled?
      env_to_boolean('USB_STERLING_SFTP_ENABLED')
    end

    def self.financial_owner_refactor_enabled?(payment_type)
      case payment_type
      when :ach
        env_to_boolean('FINANCIAL_OWNER_ACH_ENABLED')
      when :converge
        env_to_boolean('FINANCIAL_OWNER_CONVERGE_ENABLED')
      end
    end

    def self.auto_healing_enabled?
      env_to_boolean('AUTO_HEALING_ENABLED')
    end

    def self.responsys_api_username
      ENV['RESPONSYS_API_USERNAME']
    end

    def self.responsys_api_password
      ENV['RESPONSYS_API_PASSWORD']
    end

    def self.responsys_push_campaign_name
      ENV['RESPONSYS_PUSH_CAMPAIGN_NAME']
    end

    def self.transmission_gateway_key_data
      if ENV['NEW_TRANSMISSION_SERVER']
        Rails.root.join('etc/ssl/transmission_key_data').read
      else
        Rails.root.join('etc/ssl/us_bank_key_data').read
      end
    end

    def self.render_contract_from_templateflow?
      env_to_boolean('RENDER_CONTRACT_FROM_TEMPLATEFLOW')
    end

    def self.templateflow_allow_draft_templates?
      return false if acts_as_prod?

      env_to_boolean('TEMPLATEFLOW_ALLOW_DRAFT_TEMPLATES')
    end

    def self.render_rbd_from_tflow_dev?
      env_to_boolean('RENDER_RBD_FROM_TFLOW_DEV')
    end

    def self.render_pay_method_agreement_from_tflow_dev?
      env_to_boolean('RENDER_PAY_METHOD_AGREEMENT_FROM_TFLOW_DEV')
    end

    def self.render_noaa_from_tflow_dev?
      env_to_boolean('RENDER_NOAA_FROM_TFLOW_DEV')
    end

    def self.two_factor_authentication?
      env_to_boolean('TWO_FACTOR_AUTHENTICATION')
    end

    def self.auto_login_after_email_confirm_disabled?
      env_to_boolean('DISABLE_AUTO_LOGIN_AFTER_EMAIL_CONFIRM')
    end

    def self.us_bank_ach_upload_on?
      env_to_boolean('US_BANK_ACH_UPLOAD_ON')
    end

    def self.templateflow_welcome_emails
      valid_types = ['leads', 'organic', 'phone_application', 'refinance']
      valid_types & (ENV['TF_WELCOME_EMAILS'] || '').split(',').map(&:strip)
    end

    def self.is_templateflow_welcome_email?(type)
      templateflow_welcome_emails.include?(type)
    end

    def self.turn_off_emails?
      return false unless Rails.env.development? # local machine only

      env_to_boolean('TURN_OFF_EMAILS')
    end

    def self.mailcatcher_running?
      # check locally
      `which mailcatcher`
      if $CHILD_STATUS.success?
        running = `ps aux | grep mailcatcher`.lines.reject { |l| l =~ /grep/ }
        return true if running.present?
      end

      # Execute the command to make sure docker exists
      `docker -v > /dev/null 2>&1`

      # If we are inside docker or docker is not installed on the system,
      # we don't want to fail
      if $?.success?
        # check in docker, assuming the container is named mailcatcher
        docker_running = `docker ps --filter "name=mailcatcher" --filter "status=running" --format "{{.Names}}"`.lines
        docker_running.present?
      else
        false
      end
    end

    def self.validate_zip_code_match_on_not_prod?
      env_to_boolean('VALIDATE_ZIP_CODE_MATCH_ON_NOT_PROD')
    end

    def self.disable_template_flow_email_sends
      env_to_boolean('DISABLE_TEMPLATE_FLOW_EMAIL_SENDS')
    end

    def self.disable_template_flow_variable_cache
      (integration_environment? && !env_to_boolean('ENABLE_TEMPLATE_FLOW_VARIABLE_CACHE')) ||
        (production_env? && env_to_boolean('DISABLE_TEMPLATE_FLOW_VARIABLE_CACHE'))
    end

    def self.redis_pii_encryption_key
      @redis_pii_encryption_key ||= ENV['REDIS_PII_ENCRYPTION_KEY'].nil? ? nil : Base64.strict_decode64(ENV['REDIS_PII_ENCRYPTION_KEY'])
    end

    def self.logger_redis_url
      ENV['LOGGER_REDIS_URL']
    end

    def self.dashboard_activate_card_url
      ENV['DASHBOARD_ACTIVATE_CARD_URL']
    end

    def self.enable_dark_verifications_refresh_for_not_assigned
      env_to_boolean('ENABLE_DARK_VER_REFRESH_NOT_ASSIGNED')
    end

    def self.operational_charge_off_enabled?
      env_to_boolean('OPERATIONAL_CHARGE_OFF_ENABLED')
    end

    def self.threat_metrix_org_id
      ENV['THREAT_METRIX_ORG_ID']
    end

    def self.threat_metrix_api_key
      ENV['THREAT_METRIX_API_KEY']
    end

    def self.neuro_id_base_url
      ENV['NEURO_ID_BASE_URL']
    end

    def self.neuro_id_report_api_key
      ENV['NEURO_ID_REPORT_API_KEY']
    end

    def self.allow_mock_user_from_omniauth?
      env_to_boolean('ENABLE_OMNIAUTH_TEST_MODE') && !production_env?
    end

    def self.force_ssl?
      Avant::Env.env_to_boolean('FORCE_SSL')
    end

    def self.hsts_enabled?
      Avant::Env.env_to_boolean('HSTS_ENABLED')
    end

    def self.income_amount_decision_enabled?
      env_to_boolean('INCOME_AMOUNT_DECISION_ENABLED')
    end

    def self.income_pass_decision_enabled?
      env_to_boolean('INCOME_PASS_DECISION_ENABLED')
    end

    def self.enable_applicant_matches?
      env_to_boolean('ENABLE_APPLICANT_MATCHES')
    end

    def self.new_webbank_purchase_file_enabled?
      return false if TenantDefinitions.to_sym != :avant

      env_to_boolean('NEW_WEBBANK_PURCHASE_FILE_ENABLED')
    end

    def self.fe_apply_versioning_api_key
      ENV['FE_APPLY_VERSIONING_API_KEY']
    end

    def self.disable_jwt_in_url?
      env_to_boolean('DISABLE_JWT_IN_URL')
    end

    def self.enable_cross_sell_mock_customer_helper?
      env_to_boolean('ENABLE_CROSS_SELL_MOCK_CUSTOMER_HELPER')
    end

    def self.optimizely_sdk_key
      ENV['OPTIMIZELY_SDK_KEY']
    end

    def self.risky_timezones
      reports = ENV.fetch('RISKY_TIMEZONES', '').strip
      reports.empty? ? [] : reports.split(',')
    end

    def self.lexisnexis_fraud_intelligence_url
      ENV['LEXISNEXIS_FRAUD_INTELLIGENCE_URL']
    end

    def self.lexisnexis_fraud_intelligence_username
      ENV['LEXISNEXIS_FRAUD_INTELLIGENCE_USERNAME']
    end

    def self.lexisnexis_fraud_intelligence_password
      ENV['LEXISNEXIS_FRAUD_INTELLIGENCE_PASSWORD']
    end

    module POS
      def self.tester_token
        ENV['POS_TESTER_TOKEN']
      end
    end

    module Cx

      def self.turnstile_site_key
        ENV['TURNSTILE_SITE_KEY']
      end

      def self.turnstile_secret_key
        ENV['TURNSTILE_SECRET_KEY']
      end

      def self.turnstile_enabled?
        turnstile_site_key.present? && turnstile_secret_key.present?
      end

      def self.tester_token
        ENV['CX_TESTER_TOKEN']
      end

      def self.customer_deletion_enabled?
        Avant::Env.env_to_boolean('CUSTOMER_DELETION_ENABLED')
      end

      def self.welcome_back_page_enabled?
        Avant::Env.env_to_boolean('CX_WELCOME_BACK_PAGE_ENABLED')
      end

      def self.implicit_application_redirect_enabled?
        Avant::Env.env_to_boolean('CX_IMPLICIT_APPLICATION_REDIRECT_ENABLED')
      end

      def self.blocked_from_new_app_ip_addresses
        ENV['BLOCKED_FROM_NEW_APP_IP_ADDRESSES']
      end

      def self.feature_enabled?(env_var_name)
        env_var_enabled_name = "CX_FEATURE_#{env_var_name}_ENABLED"
        Avant::Env.env_to_boolean(env_var_enabled_name)
      end

      def self.feature_percentages_hash(env_var_name)
        env_var_percentages_name = "CX_FEATURE_#{env_var_name}_PERCENTAGES"
        # an empty string to_i here returns 0, that's expected
        env_var_value = ENV[env_var_percentages_name]
        return {} if env_var_value.blank?

        Rack::Utils.parse_nested_query(env_var_value)
      end

      def self.auto_redirect_ver_dash_disabled?
        Avant::Env.env_to_boolean('AUTO_REDIRECT_VER_DASH_DISABLED')
      end

      def self.hide_other_apps_if_funded?
        Avant::Env.env_to_boolean('HIDE_OTHER_APPS_IF_FUNDED')
      end

      def self.customer_application_experiments_disabled?
        Avant::Env.env_to_boolean('CUSTOMER_APPLICATION_EXPERIMENTS_DISABLED')
      end

      def self.neuro_id_api_key
        ENV['NEURO_ID_API_KEY']
      end

      def self.demo_pages_enabled?
        Avant::Env.env_to_boolean('DEMO_PAGES_ENABLED')
      end
    end

    module Adjustment
      def self.calc_notification_enabled?
        ENV['ADJUSTMENT_CALC_NOTIFICATION_ENABLED']
      end

      def self.calc_notification_url
        ENV['ADJUSTMENT_CALC_NOTIFICATION_URL']
      end

      def self.calc_notification_key
        ENV['ADJUSTMENT_CALC_NOTIFICATION_KEY']
      end
    end

    module Auth0
      def self.enabled?
        configured? # temp alias
      end

      def self.configured?
        !!(client_id && client_secret)
      end

      def self.customer_login_enabled?
        Avant::Env.env_to_boolean('AUTH0_CUSTOMER_LOGIN_ENABLED')
      end

      def self.ensure_user?
        Avant::Env.env_to_boolean('AUTH0_ENSURE_USER')
      end

      # The "default" auth0 api key
      def self.basic_auth0_api_key
        # For now, we use a single API key for all auth0 services
        custom_db_api_key
      end

      # The auth0 api key for the Custom DB service
      def self.custom_db_api_key
        ENV['AUTH0_CUSTOM_DB_API_KEY']
      end

      def self.client_id
        ENV['AUTH0_CLIENT_ID']
      end

      def self.client_secret
        ENV['AUTH0_CLIENT_SECRET']
      end

      def self.domain
        ENV['AUTH0_DOMAIN']
      end

      def self.iss_domain
        ENV['AUTH0_ISS_DOMAIN'] || self.domain
      end

      def self.custom_domain
        ENV['AUTH0_CUSTOM_DOMAIN']
      end

      def self.cookie_domain
        ENV['AUTH0_COOKIE_DOMAIN']
      end

      def self.auth_db_record_import_key
        ENV['AUTH_DB_RECORD_IMPORT_KEY']
      end

      def self.user_info_jwk
        ENV.fetch('AUTH0_USER_INFO_JWK')
      end

      def self.identity_provider_logout_url
        ENV['IDENTITY_PROVIDER_LOGOUT_URL']
      end
    end

    module AWS
      def self.default_bucket_name
        legacy_default_bucket_name || policy_default_bucket_name
      end

      def self.policy_default_bucket_name
        default_config = AppConfig.s3_mpi_interfaces.default
        default_config[Rails.env].try(:bucket_name) || default_config.default.bucket_name
      end

      def self.legacy_default_bucket_name
        case Rails.env
        when 'production'
          if ENV['HEROKU_ENABLED'].present?
            ENV['BUCKETEER_BUCKET_NAME']
          else
            ENV['AWS_S3_DEFAULT_BUCKET']
          end
        when 'development'
          ENV['AWS_S3_DEV_BUCKET']
        else
          'avant_test'
        end
      end

      def self.aws_bucket_region
        if ENV['HEROKU_ENABLED'].present?
          ENV['BUCKETEER_AWS_REGION']
        else
          ENV['AWS_BUCKET_REGION']
        end
      end
    end

    module PdfKit
      def self.page_size
        ENV['PDFKIT_PAGE_SIZE']
      end

      def self.viewport_size
        ENV['PDFKIT_VIEWPORT_SIZE']
      end

      def self.zoom
        ENV['PDFKIT_ZOOM']
      end
    end

    module Test
      def self.al_hacks? # avant-exec-demo test
        return false if Avant::Env.production_env?

        Avant::Env.env_to_boolean('AL_HACKS')
      end

      def self.decline_monetization_test_partner_shortcuts?
        Avant::Env.env_to_boolean('DECLINE_MONETIZATION_PARTNER_SHORTCUTS')
      end

      def self.redis_off?
        Avant::Env.env_to_boolean('NO_CACHING_IN_TEST')
      end

      def self.stubbed_score_config(key)
        case key
        when :credit_model      then return 'STUBBED_MODEL_SCORE',             Kernel.method(:Float)
        when :fraud_model       then return 'STUBBED_FRAUD_MODEL_SCORE',       Kernel.method(:Float)
        when :fico              then return 'STUBBED_FICO',                    Kernel.method(:Integer)
        when :vantage           then return 'STUBBED_VANTAGE',                 Kernel.method(:Integer)
        when :vantage3          then return 'STUBBED_VANTAGE3',                Kernel.method(:Integer)
        when :soft_fraud        then return 'STUBBED_SOFT_FRAUD_SCORE',        Kernel.method(:Float)
        when :income_model      then return 'STUBBED_INCOME_MODEL_SCORE',      Kernel.method(:Float)
        when :activity_model    then return 'STUBBED_ACTIVITY_MODEL_SCORE',    Kernel.method(:Float)
        when :utilization_model then return 'STUBBED_UTILIZATION_MODEL_SCORE', Kernel.method(:Float)
        when :cashflow_model    then return 'STUBBED_CASHFLOW_MODEL_SCORE',    Kernel.method(:Float)
        end
        raise ArgumentError, "unknown stubbed_score key: #{key.inspect}"
      end

      def self.stubbed_score_value(key)
        env_name, caster = stubbed_score_config(key)
        begin
          caster.call(ENV[env_name])
        rescue StandardError
          nil
        end
      end

      def self.stubbed_score_enabled?(key)
        return false if Avant::Env.acts_as_prod? || Avant::Env.ignore_mock?('credit_model_service')

        !!stubbed_score_value(key)
      end

      {
        credit_model:      'model',
        fraud_model:       'fraud_model',
        fico:              'fico',
        vantage:           'vantage',
        vantage3:          'vantage3',
        soft_fraud:        'soft_fraud',
        income_model:      'income_model',
        activity_model:    'activity_model',
        utilization_model: 'utilization_model',
        cashflow_model:    'cashflow_model',
      }.each do |key, orig|
        define_singleton_method(:"stubbed_#{orig}_score") { stubbed_score_value(key) }
        define_singleton_method(:"stubbed_#{orig}_score_enabled?") { stubbed_score_enabled?(key) }
      end
    end

    module Cleave
      def self.enabled?
        Avant::Env.env_to_boolean('SERVICING_CLEAVE_ENABLED')
      end
    end

    module CreditReports
      def self.test_run?
        !Avant::Env.production_env?
      end

      module Experian
        def self.ecal_url
          ENV['EXPERIAN_ECAL_URL']
        end

        def self.username
          ENV['EXPERIAN_USERNAME']
        end

        def self.password_secret_key
          ENV['EXPERIAN_PASSWORD_SECRET_KEY']
        end

        def self.stubbed?
          Avant::Env.env_to_boolean('STUBBED_EXPERIAN_CREDIT_REPORT')
        end

        module JSON
          def self.domain
            ENV.fetch('EXPERIAN_DOMAIN')
          end

          def self.username
            ENV.fetch('EXPERIAN_USERNAME')
          end

          def self.client_id
            ENV.fetch('EXPERIAN_CLIENT_ID')
          end

          def self.client_secret
            ENV.fetch('EXPERIAN_CLIENT_SECRET')
          end
        end
      end

      module Equifax
        def self.oauth_endpoint
          ENV['EQUIFAX_OAUTH_ENDPOINT']
        end

        def self.oauth_username
          ENV['EQUIFAX_OAUTH_USERNAME']
        end

        def self.oauth_password
          ENV['EQUIFAX_OAUTH_PASSWORD']
        end

        def self.oauth_scope
          ENV['EQUIFAX_OAUTH_SCOPE']
        end

        def self.report_endpoint
          ENV['EQUIFAX_REPORT_ENDPOINT']
        end

        def self.endpoint
          ENV['EQUIFAX_TV_ENDPOINT']
        end

        def self.password
          ENV['EQUIFAX_TV_PASSWORD']
        end

        def self.use_stubbed_report?
          Avant::Env.env_to_boolean('USE_STUBBED_EQUIFAX_CREDIT_REPORT')
        end
      end
    end

    module Easy

      def self.stubbed_applicants_enabled?
        Avant::Env.env_to_boolean('CK_EASY_STUBBED_APPLICANTS_ENABLED')
      end

      def self.skip_oauth?
        Avant::Env.env_to_boolean('CK_EASY_SKIP_OAUTH')
      end

      def self.ver_disabled?
        Avant::Env.integration_environment? && Avant::Env.env_to_boolean('CK_EASY_VER_DISABLED')
      end

      def self.exceptions_enabled?
        Avant::Env.integration_environment? && Avant::Env.env_to_boolean('CK_EASY_EXCEPTIONS_ENABLED')
      end

      def self.avant_private_key
        # decode the encoded env var
        @avant_private_key ||= ENV['CK_EASY_AVANT_PRIVATE_KEY_ENCODED'] && Base64.strict_decode64(ENV['CK_EASY_AVANT_PRIVATE_KEY_ENCODED'])
      end

      def self.avant_passphrase
        ENV['CK_EASY_AVANT_PASSPHRASE']
      end

      def self.avant_private_key_previous
        # decode the encoded env var
        @avant_private_key_previous ||= ENV['CK_EASY_AVANT_PRIVATE_KEY_ENCODED_PREVIOUS'] && Base64.strict_decode64(ENV['CK_EASY_AVANT_PRIVATE_KEY_ENCODED_PREVIOUS'])
      end

      def self.avant_passphrase_previous
        ENV['CK_EASY_AVANT_PASSPHRASE_PREVIOUS']
      end

      def self.karma_public_key
        karma_public_key_decoded || ENV['CK_EASY_KARMA_PUBLIC_KEY']
      end

      def self.karma_public_key_decoded
        @karma_public_key_decoded ||= ENV['CK_EASY_KARMA_PUBLIC_KEY_ENCODED'] && Base64.strict_decode64(ENV['CK_EASY_KARMA_PUBLIC_KEY_ENCODED'])
      end

    end

    module Invitation
      def self.worker_disabled?
        Avant::Env.env_to_boolean('INVITATION_WORKER_DISABLED')
      end

      module Gpg
        def self.passphrase
          ENV.fetch('INVITATION_GPG_PASSPHRASE')
        end

        def self.secret_key
          ENV.fetch('INVITATION_GPG_SECRET_KEY')
        end
      end

      module Sftp
        def self.port
          ENV.fetch('INVITATION_SFTP_PORT')
        end

        def self.host
          ENV.fetch('INVITATION_SFTP_HOST')
        end

        def self.username
          ENV.fetch('INVITATION_SFTP_USERNAME')
        end

        def self.password
          ENV.fetch('INVITATION_SFTP_PASSWORD')
        end

        def self.private_key
          ENV.fetch('INVITATION_SFTP_PRIVATE_KEY')
        end
      end
    end

    module PartnerApiManager
      def self.override_mocks?
        Avant::Env.env_to_boolean('OVERRIDE_PARTNER_API_MANAGER_MOCK_SERVICE')
      end

      def self.inbound_partner_secret
        ENV.fetch('PARTNER_API_MANAGER_INBOUND_PARTNER_SECRET')
      end

      def self.inbound_encryption_key
        ENV.fetch('PARTNER_API_MANAGER_INBOUND_ENCRYPTION_KEY')
      end
    end

    module AccountManagementApiManager
      def self.inbound_partner_secret
        ENV.fetch('AM_API_MANAGER_INBOUND_PARTNER_SECRET')
      end

      def self.inbound_encryption_key
        ENV.fetch('AM_API_MANAGER_INBOUND_ENCRYPTION_KEY')
      end
    end

    module CustomerManagementPartnerApiManager
      def self.override_mocks?
        Avant::Env.env_to_boolean('OVERRIDE_CIM_PARTNER_API_MANAGER_MOCK_SERVICE')
      end
    end

    module AccountManagementPartnerApiManager
      def self.override_mocks?
        Avant::Env.env_to_boolean('OVERRIDE_AM_PARTNER_API_MANAGER_MOCK_SERVICE')
      end
    end

    module IdAnalytics
      def self.endpoint
        ENV.fetch('ID_ANALYTICS_ENDPOINT')
      end

      def self.client_id
        ENV.fetch('ID_ANALYTICS_CLIENT_ID')
      end

      def self.username
        ENV.fetch('ID_ANALYTICS_USERNAME')
      end

      def self.password
        ENV.fetch('ID_ANALYTICS_PASSWORD')
      end

      def self.oln_client_id
        ENV.fetch('ID_ANALYTICS_OLN_CLIENT_ID')
      end

      def self.oln_username
        ENV.fetch('ID_ANALYTICS_OLN_USERNAME')
      end

      def self.oln_password
        ENV.fetch('ID_ANALYTICS_OLN_PASSWORD')
      end
    end

    module LexisNexis
      def self.risk_view_account_name
        ENV.fetch('RISK_VIEW_ACCOUNT_NAME')
      end

      def self.risk_view_wsdl_url
        ENV.fetch('RISK_VIEW_WSDL_URL')
      end

      def self.risk_view_username
        ENV.fetch('RISK_VIEW_USERNAME')
      end

      def self.risk_view_password
        ENV.fetch('RISK_VIEW_PASSWORD')
      end

      def self.bridger_url
        ENV.fetch('BRIDGER_URL')
      end

      def self.bridger_client_id
        ENV.fetch('BRIDGER_CLIENT_ID')
      end

      def self.bridger_username
        ENV.fetch('BRIDGER_USERNAME')
      end

      def self.bridger_password
        ENV.fetch('BRIDGER_PASSWORD')
      end

      def self.bridger_api_key
        ENV.fetch('BRIDGER_API_KEY')
      end
    end

    module Leads
      module LendingTree
        def self.offers_url
          ENV.fetch('LENDING_TREE_OFFERS_URL')
        end

        def self.post_funding_url
          ENV.fetch('LENDING_TREE_POST_FUNDING_URL')
        end

        def self.party_id
          ENV.fetch('LENDING_TREE_PARTY_ID')
        end

        def self.username
          ENV.fetch('LENDING_TREE_USERNAME')
        end

        def self.password
          ENV.fetch('LENDING_TREE_PASSWORD')
        end
      end

      def self.enabled?
        Avant::Env.env_to_boolean('LEADS_ENABLED')
      end

      def self.mocks_enabled?
        Avant::Env.env_to_boolean('LEADS_MOCKS_ENABLED')
      end
    end

    module ExternalDecisionEngine

      def self.external_card_decision_api_uri
        ENV.fetch('EXTERNAL_CARD_DECISION_API_URI')
      end

      def self.external_card_decision_access_token
        ENV.fetch('AVANT_BASIC_AO_TOKEN')
      end

      def self.external_card_decision_enabled
        Avant::Env.env_to_boolean('EXTERNAL_CARD_DECISION_ENABLED')
      end

      def self.external_refinance_decision_enabled
        Avant::Env.env_to_boolean('EXTERNAL_REFINANCE_DECISION_ENABLED')
      end

      def self.external_loan_decision_api_uri
        ENV.fetch('EXTERNAL_LOAN_DECISION_API_URI')
      end

      def self.external_loan_decision_access_token
        ENV.fetch('AVANT_BASIC_AO_TOKEN')
      end

      def self.external_decision_access_token
        ENV.fetch('AVANT_BASIC_AO_TOKEN')
      end

      def self.external_loan_configs_api_uri
        "#{ENV.fetch('EXTERNAL_LOAN_DECISION_API_URI')}/configs"
      end

      def self.external_credit_card_configs_api_uri
        "#{ENV.fetch('EXTERNAL_CARD_DECISION_API_URI')}/configs"
      end

      def self.external_refinance_configs_api_uri
        "#{ENV.fetch('EXTERNAL_REFINANCE_DECISION_API_URI')}/configs"
      end

      def self.external_refinance_decision_api_uri
        ENV.fetch('EXTERNAL_REFINANCE_DECISION_API_URI')
      end

      def self.bypass_external_card_decisioning_experiment?
        Avant::Env.env_to_boolean('BYPASS_EXTERNAL_CARD_DECISIONING_EXPERIMENT')
      end
    end

    module RiskDetermination
      module IncomeVerInstallment
        def self.rd_api_uri
          ENV.fetch('RD_API_URI', '')
        end
      end

      module ConsentsRisks
        def self.rd_api_uri
          ENV.fetch('RD_API_URI', '')
        end
      end

      module FraudRisks
        def self.rd_api_uri
          ENV.fetch('RD_API_URI', '')
        end
      end
    end

    module PagayaDeclinePartners
      def self.pagaya_ndr_decline_partner_lead_service_uri
        ENV.fetch('PAGAYA_NDR_DECLINE_PARTNER_LEAD_SERVICE_URI')
      end

      def self.pagaya_ndr_decline_partner_lead_service_api_key
        ENV.fetch('PAGAYA_NDR_DECLINE_PARTNER_LEAD_SERVICE_API_KEY')
      end
    end

    module DeclinePartners
      def self.engine_lead_service_uri
        ENV.fetch('ENGINE_LEAD_SERVICE_URI')
      end

      def self.engine_lead_service_access_token
        ENV.fetch('ENGINE_LEAD_SERVICE_ACCESS_TOKEN')
      end
    end

    module EventPublisher
      def self.event_publisher_uri
        ENV['EVENT_PUBLISHER_URI']
      end

      def self.kafka_publish_reports
        reports = ENV.fetch('KAFKA_PUBLISH_REPORTS', '').strip
        reports.empty? ? [] : reports.split(',')
      end

      def self.kafka_environment_prefix
        ENV.fetch('KAFKA_ENVIRONMENT_PREFIX', '')
      end
    end

    module CreditPullService
      def self.credit_pull_service_enabled?
        Avant::Env.env_to_boolean('CREDIT_PULL_SERVICE_ENABLED')
      end

      def self.credit_pull_service_url
        ENV.fetch('CREDIT_PULL_SERVICE_URL') {
          |name| return 'https://credit-pull.ocala.k8s.dev.global.avant.com' unless Avant::Env.production_env?
        }
      end

      def self.credit_pull_service_path
        ENV.fetch('CREDIT_PULL_SERVICE_PATH', '/api/v1/transunion/credit-report-pass-through/')
      end

      def self.credit_pull_service_user
        ENV.fetch('CREDIT_PULL_SERVICE_USER', 'localuser')
      end

      def self.credit_pull_service_password
        ENV.fetch('CREDIT_PULL_SERVICE_PASSWORD', 'secret')
      end
    end

    module CIAM
      def self.ciam_enabled?
        Avant::Env.env_to_boolean('CIAM_ENABLED') || false
      end

      def self.ciam_replication_enabled?
        Avant::Env.env_to_boolean('CIAM_REPLICATION_ENABLED')
      end

      def self.ciam_api_url
        ENV.fetch('CIAM_API_URL', 'https://id.avant.com')
      end

      def self.ciam_auth_disabled?
        Avant::Env.env_to_boolean('CIAM_AUTH_DISABLED') || false
      end

      def self.ciam_auth_domain
        ENV['CIAM_AB_AUTH0_DOMAIN']
      end

      def self.ciam_auth_client_id
        ENV['CIAM_AB_AUTH0_CLIENT_ID']
      end

      def self.ciam_auth_client_secret
        ENV['CIAM_AB_AUTH0_CLIENT_SECRET']
      end

      def self.ciam_auth_audience
        ENV.fetch('CIAM_AB_AUTH0_AUDIENCE', 'avant-basic-api-for-ciam')
      end

    end

    def self.expose_test_account_platform_endpoint?
      !production_env?
    end

    def self.recheck_notices_before_charge_off?
      env_to_boolean('RECHECK_NOTICES_BEFORE_CHARGE_OFF')
    end

    def self.late_fee_charge_email_enabled?
      env_to_boolean('LATE_FEE_CHARGE_EMAIL_ENABLED')
    end

    module MicroFrontends
      def self.enable_micro_fronteds_local_development?
        Avant::Env.env_to_boolean('ENABLE_MICRO_FRONTENDS_LOCAL_DEVELOPMENT')
      end

      def self.development_url
        ENV.fetch('MICRO_FRONTENDS_DEVELOPMENT_URL')
      end
    end

    module AvantIncomeModel
      def self.active_income_model_version
        ENV.fetch('ACTIVE_AVANT_INCOME_MODEL_VERSION', 'income/en-US/4.0')
      end
    end

    module Plaidypus
      def self.plaidypus_cra_uri
        ENV.fetch('PLAIDYPUS_CRA_URI', '')
      end

      def self.plaidypus_payroll_income_uri
        ENV.fetch('PLAIDYPUS_PAYROLL_INCOME_URI', '')
      end

      def self.plaidypus_payroll_risk_signals_uri
        ENV.fetch('PLAIDYPUS_PAYROLL_RISK_SIGNALS_URI', '')
      end
    end

    module ReactFrontend
      def self.sentry_dsn
        ENV.fetch('REACT_FRONTEND_SENTRY_DSN')
      end

      def self.sentry_environment
        ENV.fetch('REACT_FRONTEND_SENTRY_ENVIRONMENT')
      end

      def self.rollout_percent
        ENV.fetch('REACT_FRONTEND_ROLLOUT_PERCENT', 0).to_i
      end

      def self.disallowed_sources
        ENV.fetch('REACT_FRONTEND_DISALLOWED_SOURCES', '').split(',')
      end
    end

    def self.pull_lexisnexis_fraud_intelligence_report_enabled?
      env_to_boolean('PULL_LEXISNEXIS_FRAUD_INTELLIGENCE_REPORT_ENABLED')
    end

    module Confetti
      def self.confetti_uri
        ENV.fetch('CONFETTI_URI', 'https://confetti.boston.k8s.prd.app.avant.com')
      end

      def self.confetti_env
        ENV.fetch('CONFETTI_ENV', 'prd')
      end

      def self.confetti_disabled?
        # If the env var is not set, the default value is false
        Avant::Env.env_to_boolean('CONFETTI_DISABLED')
      end
    end
  end
end
