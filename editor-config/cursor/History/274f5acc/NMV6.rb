# frozen_string_literal: true

require "set"
require "avant/env"
require "credit_card_gateway/send_request"
require "credit_card_core_gateway/send_request"
require "credit_card_core/partners/avant/api/get/accounts/product_type_information/get_by_account_id"
require "credit_card_core/partners/avant/api/get/payment_plans/get_by_account_id"
require "credit_card_core/partners/avant/api/post/payment_plans/create"
require "credit_card_core/partners/avant/api/post/accounts/onboard"
require "./platforms/account_opening/modules/card_art_manager/interface"

class CreditCardEndpointNotSetError < StandardError; end

class CcapiPurgeLogging < Amount::Event::ErrorWithContext
  SENTRY_FINGERPRINT = ["credit_card_api", "purge_logging"]
  def sentry_fingerprint
    SENTRY_FINGERPRINT
  end
end

module Avant
  module CreditCardApi
    class Base
      attr_reader :account_uuid, :customer_uuid, :credit_card_account

      VERSION = "v1"
      ACCOUNT_RESOURCE = "accounts"
      CREDIT_CARD_RESOURCE = "credit-cards"
      CUSTOMER_RESOURCE = "customers"
      VALID_TRANSACTIONS = ["posted", "pending", "declined"].freeze
      CREDIT_CARD_STATUS_LATE = "late"
      CREDIT_CARD_STATUS_CHARGED_OFF = "charged_off"
      CREDIT_CARD_STATUS_REVOKED_WITHOUT_BALANCE = "revoked_without_balance"
      CREDIT_CARD_STATUS_REVOKED_WITH_BALANCE = "revoked_with_balance"
      CREDIT_CARD_STATUS_CLOSED_WITHOUT_BALANCE = "closed_without_balance"
      CREDIT_CARD_STATUS_CLOSED_WITH_BALANCE = "closed_with_balance"
      LOST_STATUS_CODE = "L"
      STOLEN_CARD_STATUS_CODE = "U"
      CHARGED_OFF_STATUS_CODE = "Z"
      EXTERNAL_NORMAL_STATUS_CODE = " "
      EXTERNAL_ACTIVE_STATUS = "Active"
      AUTHORIZATION_BLOCK = "A"
      EXTERNAL_BANKRUPT_STATUS_CODE = "B"
      EXTERNAL_CLOSED_STATUS_CODE = "C"
      EXTERNAL_REVOKED_STATUS_CODE = "E"
      INTERNAL_DELINQUENT_STATUS_CODE = "D"
      INTERNAL_OVERLIMIT_DELINQUENT_STATUS_CODE = "X"
      FRAUD_STATUS_CODE = "88"
      BANKRUPT_STATUS_CODE = "89"
      DECEASED_STATUS_REASON_CODE = "01"
      NORMAL_STATUS_REASON_CODE = "00"
      SETTLEMENT_STATUS_REASON_CODE = "68"
      ACCOUNT_PAID_LESS_THAN_FULL_BALANCE = "AU"
      CHARGED_OFF_PAID_IN_FULL = "64"
      CHARGED_OFF_UNPAID_BALANCE_REPORTED_LOSS = "97"
      PAID_AND_CLOSED = "13"
      BANKRUPTCY_CHAPTER_7_OR_11_STATUS_REASON_CODE = "67"
      BANKRUPTCY_CHAPTER_13_STATUS_REASON_CODE = "69"
      SOLD_STATUS_REASON_CODE = "10"
      SUSPECTED_FALSE_FRAUD_CLAIM_STATUS_REASON_CODE = "57"
      ID_THEFT_STATUS_REASON_CODE = "58"
      SUSPECTED_FRAUD_APPLICATION_STATUS_REASON_CODE = "59"
      CREDIT_ABUSE_STATUS_REASON_CODE = "60"
      VALID_PHONE_TYPE = "home"
      ACH_PAYMENT_METHOD = "ach"
      DEBIT_CARD_PAYMENT_METHOD = "debit_card"
      VALID_PAYMENT_METHODS = [ACH_PAYMENT_METHOD, DEBIT_CARD_PAYMENT_METHOD].freeze
      RTC_INELIGIBLE_EXTERNAL_STATUS_CODES = [CHARGED_OFF_STATUS_CODE, STOLEN_CARD_STATUS_CODE, LOST_STATUS_CODE].freeze
      UPC_DMC_CODE = "D"
      UPC1_SOLD_OFF_CODE = "K"

      API_PREFIX_STAT = "api.credit_card_api"
      LATE_FEE_WAIVER_ERROR_STAT = "#{API_PREFIX_STAT}.late_fee_waiver.error"

      DEPRECATED_PAYMENT_ACCOUNT_USAGE_HEADER = "DeprecatedPaymentAccountUsage---"

      DEFAULT_TIMEOUT = 10

      BLANK_REWARDS_SUMMARY = {
        enabled: false,
        is_dark: false,
        rewards_type_is_dollars: true,
        balance: 0.0,
        reward_percent_of_purchase: 0.0,
        rewards_by_timeframe: {
          lifetime: {
            summary: {
              transaction_count: 0,
              reward_value: 0.0
            },
            rewards: []
          },
          this_year: {
            summary: {
              transaction_count: 0,
              reward_value: 0.0
            },
            rewards: []
          },
          last_cycle: {
            summary: {
              transaction_count: 0,
              reward_value: 0.0
            }
          },
          current_cycle: {
            summary: {
              transaction_count: 0,
              reward_value: 0.0
            }
          }
        }
      }.freeze

      ##
      # Constructor for API class, taking in a CreditCardAccount
      #
      # @param [CreditCardAccount] Card AR Model
      # @return [CreditCardApi]
      def initialize(credit_card_account)
        @credit_card_account = credit_card_account
        @account_uuid = credit_card_account.uuid
        @customer_uuid = credit_card_account.customer_uuid
      end

      def summary
        account(
          with_remote_cache: true
        )
      end

      def account(with_remote_cache: false)
        raise NotImplementedError
      end

      def local_account
        raise NotImplementedError
      end

      def autopay_plan
        raise NotImplementedError
      end

      def memos
        raise NotImplementedError
      end

      def pending_transactions(statement_date = nil)
        transactions("pending", statement_date)
      end

      def posted_transactions(statement_date = nil)
        transactions("posted", statement_date)
      end

      def declined_transactions(statement_date = nil)
        transactions("declined", statement_date)
      end

      def transactions(type, statement_date)
        raise NotImplementedError
      end

      def statements
        raise NotImplementedError
      end

      def payment_amount_strategies
        raise NotImplementedError
      end

      def statement_dates
        raise NotImplementedError
      end

      def payment_account(id = nil)
        raise NotImplementedError
      end

      def payments(id = nil, **opts)
        raise NotImplementedError
      end

      def customer
        raise NotImplementedError
      end

      def onboarding(_application_data_hash)
        raise NotImplementedError
      end

      def late_fee_waiver_eligibility
        get_account_path("late_fee_waivers/get_eligibility_info")
      rescue => exception
        ::Avant::Event::Stat.publish(
          "stat" => LATE_FEE_WAIVER_ERROR_STAT,
          "value" => 1
        )

        raise exception
      end

      def card_details
        customer_application = @credit_card_account.customer_application
        card_art_interface = ::AccountOpening::Modules::CardArtManager::Interface.new(customer_application)
        @card_details ||= card_art_interface.get_choice
      end

      def card_image_name
        card_details[:card_image_name]
      end

      def card_image_url
        card_details[:card_image_url]
      end

      def product_name
        card_details[:product_name]
      end

      # Retrieves the Fiserv UPC 14 (Universal Product Code) for the
      # credit card.
      #
      # The UPC 14 is used by Fiserv for identifying card products.
      # This value is extracted from the card_details which are
      # usually obtained from the card account api.
      #
      # Possible values:
      #   - "01": 1% rewards product
      #   - "02": 2% rewards product
      #   - "05": Major League Soccer (MLS) product
      #
      # @return [String, nil] The 14-digit Fiserv UPC code, or nil
      #   if unavailable.
      #
      # @note
      #   We are not using card details because that goes though a local
      #   model that is used by Account Opening and it doesn't have the
      #   details about UPC 14
      def fiserv_upc14
        account['client_classification_14_code']
      end

      def fiserv_upc15
        card_details[:fiserv_upc15]
      end


      private

      def get_credit_card_path(path, get_params, return_full_response: false, timeout: nil, open_timeout: nil)
        credit_card_uuid = get_params[:credit_card_id]
        raise "No credit card account found for uuid: #{credit_card_uuid}" if @credit_card_account.nil?
        get([CREDIT_CARD_RESOURCE, credit_card_uuid, path].join("/"),
          params: get_params,
          return_full_response: return_full_response,
          timeout: timeout,
          open_timeout: open_timeout)
      end

      def enabled?
        @enabled ||= Avant::Env.credit_card_api_endpoint.present?
      end

      def get_account_path(path = "", params: nil, timeout: nil, open_timeout: nil)
        raise "No account uuid specified!" if account_uuid.nil?
        path = [ACCOUNT_RESOURCE, account_uuid, path].join("/")
        get(path, params: params, timeout: timeout, open_timeout: open_timeout)
      end

      def put_account_path(path = "", params: nil, timeout: nil, open_timeout: nil)
        raise "No account uuid specified!" if account_uuid.nil?
        path = [ACCOUNT_RESOURCE, account_uuid, path].join("/")
        put(path, params, timeout: timeout, open_timeout: open_timeout)
      end

      def post_account_path(path = "", params: nil, return_full_response: false, timeout: nil, open_timeout: nil)
        raise "No account uuid specified!" if account_uuid.nil?
        path = [ACCOUNT_RESOURCE, account_uuid, path].join("/")
        post(path, params, return_full_response: return_full_response, timeout: timeout, open_timeout: open_timeout)
      end

      def get_customer_path(path = "", params: nil, return_full_response: false, timeout: nil, open_timeout: nil)
        raise "No customer uuid specified!" if customer_uuid.nil?
        get([CUSTOMER_RESOURCE, customer_uuid, path].join("/"),
          params: params, return_full_response: return_full_response, timeout: timeout, open_timeout: open_timeout)
      end

      def post_customer_path(path = "", post_params, return_full_response: false, timeout: nil, open_timeout: nil)
        raise "No customer uuid specified!" if customer_uuid.nil?
        post([CUSTOMER_RESOURCE, customer_uuid, path].join("/"),
          post_params,
          return_full_response: return_full_response,
          timeout: timeout,
          open_timeout: open_timeout)
      end

      def post_credit_card_path(path = "", post_params, return_full_response: false, timeout: nil, open_timeout: nil)
        credit_card_uuid = post_params[:credit_card_id]
        post([CREDIT_CARD_RESOURCE, credit_card_uuid, path].join("/"),
          post_params,
          return_full_response: return_full_response,
          timeout: timeout,
          open_timeout: open_timeout)
      end

      def type_with_optional_id_url_builder(type, id)
        url = type
        url += "/#{id}" if id.present?
        url
      end

      def log_purge_account(path, params, message)
        if Flipper.enabled?("credit_card_account_purge_logging")
          if credit_card_account.older_inactive_account?
            Amount::Event::Alert.debug_exception(
              CcapiPurgeLogging.new(
                message,
                path: path,
                params: params
              )
            )
          end
        end
      end

      def get(path, params: nil, return_full_response: false, timeout: nil, open_timeout: nil)
        raise CreditCardEndpointNotSetError unless enabled?

        log_purge_account(path, params, "Purge logging on get request")

        api_results = CreditCardGateway::SendRequest.call(http_method: :get,
          path: path,
          payload: params,
          return_full_response: return_full_response,
          alert_error: false, # we will handle error here
          timeout: timeout || DEFAULT_TIMEOUT,
          open_timeout: open_timeout || DEFAULT_TIMEOUT)

        if api_results.failure?
          # if there is a failure, we've already escalated it to Sentry via
          # Amount::Event::Alert::Error, but we do need to raise an exception here
          # as well.
          raise CreditCardGateway::SendRequest::CreditCardApiCallError.new(
            "Received error response for GET request. Status #{api_results.failure[:status]}: #{api_results.failure[:error]}",
            api_results.failure
          )
        else
          Hashie::Mash.new(api_results.value)
        end
      end

      def post(path, post_params, return_full_response: false, timeout: nil, open_timeout: nil)
        raise CreditCardEndpointNotSetError unless enabled?

        log_purge_account(path, post_params, "Purge logging on post request")

        CreditCardGateway::SendRequest.call(http_method: :post,
          path: path,
          payload: post_params,
          return_full_response: return_full_response,
          timeout: timeout || DEFAULT_TIMEOUT,
          open_timeout: open_timeout || DEFAULT_TIMEOUT)
      end

      def put(path, put_params, return_full_response: false, timeout: nil, open_timeout: nil)
        raise CreditCardEndpointNotSetError unless enabled?

        log_purge_account(path, put_params, "Purge logging on put request")

        CreditCardGateway::SendRequest.call(http_method: :put,
          path: path,
          payload: put_params,
          return_full_response: return_full_response,
          timeout: timeout || DEFAULT_TIMEOUT,
          open_timeout: open_timeout || DEFAULT_TIMEOUT)
      end
    end

    class PreIssuance < Base
      def account(with_remote_cache: false)
        # credit cards use UUIDs for IDs, account for that by
        # swapping ID w/ UUID and adding simple_id (ID)
        Hashie::Mash.new(credit_card_account.attributes.merge({
          id: credit_card_account.uuid,
          simple_id: credit_card_account.id,
          customer_id: customer_uuid,
          status: credit_card_account.status,
          # credit card api sends percentages as ...percentages and we store them as decimals
          purchase_apr: credit_card_account.apr_percentage.try(:*, 100),
          cash_advance_apr: credit_card_account.cash_apr_percentage.try(:*, 100),
          # only the fdr gateway is setting the capped apr values as its own field
          maximum_merchandise_apr: credit_card_account.apr_percentage.try(:*, 100),
          annual_membership_fee_amount_cents: credit_card_account.annual_membership_fee_amount_cents,
          credit_limit_cents: credit_card_account.credit_line_amount_cents
        }))
      end

      def local_account
        nil
      end

      def autopay_plan
        nil
      end

      def memos
        []
      end

      def transactions(type, statement_date)
        []
      end

      def statements
        []
      end

      def statement_dates
        []
      end

      def payment_amount_strategies
        nil
      end

      def payment_account(id = nil)
        id.nil? ? [] : nil
      end

      def payments(id = nil, **opts)
        id.nil? ? [] : nil
      end

      def payment_plans
        []
      end

      def onboarding(application_data_hash)
        CreditCardCoreGateway::SendRequest.call(
          api: CreditCardCore::Partners::Avant::Api::Post::Accounts::Onboard,
          payload: {onboarding_info: application_data_hash}
        )
      end

      def rewards_summary
        BLANK_REWARDS_SUMMARY
      end

      def product_type_information
        nil
      end

      def brand
        card_details[:brand] || "avant"
      end

      def activation_attempt_status(channel:)
        nil
      end
    end

    class PostIssuance < Base
      def account(with_remote_cache: false)
        settlement_status_enabled = Flipper.enabled?("settlement_status")
        acct = if settlement_status_enabled
          get_account_path(params: {with_bureau_info: settlement_status_enabled, with_cache: with_remote_cache}).account
        else
          get_account_path(params: {with_cache: with_remote_cache}).account
        end
        interface = credit_card_account&.servicing_interface

        if interface
          should_set_cache = !interface.has_daily_cached_credit_card_data?
          interface.set_credit_card_daily_cache(data: acct, source: :passed_in_api_call) if should_set_cache
        end

        acct
      end

      def local_account
        get_account_path(params: {local_data_only: true}).account
      end

      def autopay_plan
        get_account_path("autopay-plans").autopay_plan
      end

      def enroll_autopay(strategy)
        params = {
          strategy: strategy
        }
        post_account_path("autopay-plans/enroll", params: params)
      end

      def unenroll_autopay
        post_account_path("autopay-plans/unenroll")
      end

      def scheduled_payments
        get_account_path("payments/scheduled").payments
      end

      def pending_payments
        get_account_path("payments/pending").payments
      end

      def memos
        get_account_path("memos").memos
      end

      def transactions(type, statement_date)
        raise ArgumentError unless VALID_TRANSACTIONS.include?(type)
        query_string = statement_date.present? ? "?statement_date=#{statement_date}" : ""
        get_account_path("transactions/#{type}#{query_string}")
          .transactions
          .map do |t|
            t.merge({__type_for_graphql: "CreditCard#{type.titleize}Transaction"})
          end
      end

      def statements
        get_account_path("statements/summary", timeout: Avant::Env.ccapi_timeouts[:statements]).statements
      end

      def payment_amount_strategies
        get_account_path("payment-amount-strategies")
      end

      def statement_dates
        get_account_path("statement-dates")
      end

      def payment_account(id = nil)
        # We're deprecating this so we want to know if it's being used
        # anywhere.
        json_context = Oj.dump({stacktrace: caller})
        Amount::Event::Alert.info(DEPRECATED_PAYMENT_ACCOUNT_USAGE_HEADER + json_context)

        url = type_with_optional_id_url_builder("payment-accounts", id)
        api_response = get_account_path(url)
        api_response.payment_account
      end

      def update_payment_account(params)
        # 8/7/2019 this calls out to credit-card-api, which calls
        # back into avant-basic via graphql mutation UpsertBankAccount

        # We're deprecating this so we want to know if it's being used
        # anywhere.
        json_context = Oj.dump({stacktrace: caller})
        Amount::Event::Alert.info(DEPRECATED_PAYMENT_ACCOUNT_USAGE_HEADER + json_context)
        post_account_path("payment-accounts", params: params)
      end

      def update_payment_account_id(params)
        post_account_path("payment-accounts/update_payment_account", params: params)
      end

      def payments(id = nil, merge_payment_accounts: true)
        url = type_with_optional_id_url_builder("payments", id)
        params = {skip_payment_accounts: true}
        api_response = get_account_path(url, params: params)
        if merge_payment_accounts
          merge_payment_accounts_into_payments(api_response.payments)
        else
          api_response.payments
        end
      end

      def merge_payment_accounts_into_payments(payments)
        return payments if payments.blank?
        uuids = payments.map { |payment| payment[:payment_account_id] }.reject(&:blank?).uniq
        return payments if uuids.blank?
        banks = BankAccount.where(uuid: uuids).to_a
        return payments if banks.blank?
        merger = banks.each_with_object({}) do |bank, acc|
          acc[bank.uuid] = Hashie::Mash.new(payment_account: {
            id: bank.uuid,
            simple_id: bank.id,
            bank_name: bank.bank_name || bank.humanized_bank_name,
            account_type: bank.humanized_account_type,
            bank_account_number: bank.decorate.obfuscated_account_number,
            bank_routing_number: bank.routing_number,
            bad_account: bank.bad_account
          })
        end
        payments.map do |payment|
          uuid = payment[:payment_account_id]
          merger[uuid] ? payment.merge(merger[uuid]) : payment
        end
      end
      private :merge_payment_accounts_into_payments

      def make_payment(params)
        raise ArgumentError unless VALID_PAYMENT_METHODS.include?(params[:payment_method])
        post_account_path("payments", params: params, timeout: Avant::Env.ccapi_timeouts[:make_payment])
      end

      def customer
        api_response = get_customer_path
        api_response.customer
      end

      def cancel_reissue(params)
        post_credit_card_path("cancel-reissue", params, return_full_response: true)
      end

      def delay_reissues
        put_account_path("delay-reissues")
      end

      def reissue(reissue_type, params)
        reissue_path =
          case reissue_type
          when "non_receipt"
            "non-receipt"
          when "force_emboss"
            "force-emboss"
          end

        post_credit_card_path(reissue_path, params, return_full_response: true)
      end

      def most_recent_reissue_date(params)
        get_credit_card_path("most-recent-reissue-date", params)
      end

      def update_paperless(paperless_params)
        url = "settings"
        put_account_path(url, params: paperless_params)
      end

      def enroll_fraud_alerts(fraud_alert_params)
        url = "fraud-alerts/enroll"
        post_account_path(url, fraud_alert_params)
      end

      def unenroll_fraud_alerts
        url = "fraud-alerts/unenroll"
        post_account_path(url)
      end

      def update_fraud_strategy(strategy_update_params)
        url = "update-fraud-strategy"
        post_credit_card_path(url, strategy_update_params, return_full_response: true)
      end

      def update_fraud_cooldown(fraud_cooldown_update_params)
        url = "update-fraud-cooldown"
        post_credit_card_path(url, fraud_cooldown_update_params, return_full_response: true)
      end

      def notify_travel(notify_travel_params)
        url = "notify-travel"
        post_credit_card_path(url, notify_travel_params, return_full_response: true)
      end

      def update_fraud_behavior(fraud_behavior_params)
        url = "update-fraud-behavior"
        post_credit_card_path(url, fraud_behavior_params, return_full_response: true)
      end

      def update_income_and_housing(params)
        put_account_path("income-and-housing", params: params)
      end

      def set_authorization_block(params)
        url = "set-authorization-block"
        post_credit_card_path(url, params, return_full_response: true)
      end

      def fee_only_dq?
        res = get_account_path("fee-only-delinquent")
        res[:fee_only_delinquent]
      end

      # Revoke an account using the status_reason given
      # as a side effect it invalidates the credit card account
      # cache
      #
      # @param status_reason [String] The status reason to revoke
      #   the account, valid values are: "60", "59", "58", "57"
      #
      # @return [Hashie::Mash]
      def revoke_account(status_reason:)
        params = {
          status_reason: status_reason
        }

        put_account_path("revoke", params: params).tap do
          @credit_card_account.invalidate_cached_account!
          @credit_card_account.servicing_interface.clear_daily_cached_credit_card_data!
        end
      end

      def close_account(status_reason: nil)
        params = if status_reason
          {
            status_reason: status_reason
          }
        end

        res = put_account_path("close", params: params)
        @credit_card_account.invalidate_cached_account!
        @credit_card_account.servicing_interface.clear_daily_cached_credit_card_data!
        res
      end

      def mark_account_as_living
        params = {
          params: {
            external_status_reason_code: NORMAL_STATUS_REASON_CODE
          }
        }
        res = put_account_path("set-external-status-reason-code", params)
        @credit_card_account.invalidate_cached_account!
        @credit_card_account.servicing_interface.clear_daily_cached_credit_card_data!
        res
      end

      def add_refund(params)
        post_account_path("add-refund", params: params)
      end

      def get_pending_late_fee_waivers
        get_account_path("late_fee_waivers/pending").pending_late_fee_waivers
      end

      def create_late_fee_waiver(params)
        post_account_path("late_fee_waivers", params: params)
      end

      def resolve_late_fee_waiver(params)
        post_account_path("late_fee_waivers/resolve", params: params)
      end

      def most_recent_late_fee
        get_account_path("late_fee_waivers/most_recent_late_fee").most_recent_late_fee
      end

      def validate_cli_request
        post_account_path("credit-lines/validate")
      end

      def request_cli(params)
        post_account_path("credit-lines/request", params: params)
      end

      def cancel_payment(payment_id)
        post_account_path("payments/#{payment_id}/cancel")
      end

      def posted_payments_by_x_cycle(params)
        get_account_path("payments/posted_by_x_cycle", params: params)
      end

      def activate_card(credit_card_last_four, ssn_last_four, channel)
        post_customer_path("activate_card", {
          credit_card_last_four: credit_card_last_four,
          ssn_last_four: ssn_last_four,
          channel: channel
        }, return_full_response: false)
      end

      # Valid error messages and their corresponding failure reasons:
      # - "No matching cards exist" → FAILURE_REASON_NO_ACTIVATABLE_CARD
      # - "Account cannot be activated" → FAILURE_REASON_PII_MISMATCH
      # - "Customer not found" → FAILURE_REASON_NO_CUSTOMER
      # - "Unverified email" → FAILURE_REASON_UNVERIFIED_EMAIL
      # - All other messages → FAILURE_REASON_OTHER
      def log_disqualified_activation_attempt(channel:, error_message:)
        post_customer_path(
          "logdisqualifiedactivationattempt",
          {
            channel: channel,
            error_message: error_message
          },
          return_full_response: false
        )
      end

      def activation_attempt_status(channel:)
        get_customer_path("activation_attempt_status", params: {channel: channel})
      end

      def complete_onboarding
        post_account_path("onboard-complete", return_full_response: true)
      end

      def opt_out
        post_account_path("terms-opt-out/opt-out")
      end

      def terms_opt_out
        get_account_path("terms-opt-out")
      end

      def initiate_disaster_relief
        post_account_path("disaster-relief/create")
      end

      def approve_hardship_relief(hardship_identifier:, hardship_config:)
        post_account_path("hardship-relief/approve",
          params: {hardship_identifier: hardship_identifier, hardship_config: hardship_config})
      end

      def payment_plans
        if Avant::Env::CreditCardCore.enable_cc_core_payment_plan_cache_get?
          ::CreditCardCore::Partners::Avant::Api::Get::PaymentPlans::GetByAccountId.call!(
            account_id: account_uuid
          )[:payment_plans].map(&:to_h).map(&:with_indifferent_access)
        else
          get_account_path("payment_plans")[:payment_plans]
        end
      end

      def create_payment_plan(structure:, start_date:, terms:, amount_cents:, monthly_payment_amount_cents:, end_date:)
        if Avant::Env::CreditCardCore.enable_cc_core_create_payment_plan?
          ::CreditCardCore::Partners::Avant::Api::Post::PaymentPlans::Create.call!(
            payment_plan: {
              account_id: account_uuid,
              structure: structure,
              start_date: start_date,
              amount_cents: amount_cents,
              terms: terms,
              monthly_payment_amount_cents: monthly_payment_amount_cents,
              end_date: end_date
            }
          )
        else
          post_account_path("payment_plans", params: {
            account_id: account_uuid,
            structure: structure,
            start_date: start_date,
            amount_cents: amount_cents,
            terms: terms,
            monthly_payment_amount_cents: monthly_payment_amount_cents,
            end_date: end_date
          })
        end
      end

      def generate_payment_plan_terms(opts)
        post_account_path("payment_plans/generate_terms", params: opts)
      end

      def terminate_any_active_plans
        post_account_path("payment_plans/terminate_any_active_plans")
      end

      # Updates the external status of a Credit Card customer after
      # the Debt Management Company info was added
      #
      # Use update_external_status_for_added_dmc method on CreditCardAccount to hit this API
      # @api private
      def update_external_status_for_added_dmc
        put_account_path("update-status-for-added-dmc")
      end

      def rewards_summary
        if credit_card_account.servicing_interface.rewards_info_available?
          begin
            get_account_path("rewards/summary")[:rewards_summary]
          rescue => e
            Amount::Event::Alert.warn(
              "Failed to retrieve rewards summary for account_uuid: #{account_uuid}: #{e.message}"
            )
            BLANK_REWARDS_SUMMARY
          end
        else
          BLANK_REWARDS_SUMMARY
        end
      end

      def product_type_information
        CreditCardCore::Partners::Avant::Api::Get::Accounts::ProductTypeInformation::GetByAccountId.call!(
          account_id: @account_uuid
        )[:product_type_information]&.info&.to_h
      end

      def product_type
        product_type_information&.dig(:product_type)
      end

      def brand
        product_type_information&.dig(:brand) || "avant"
      end
    end

    ##
    # CreditCardApiFactory
    # Returns the proper CreditCard Class
    class Factory
      ##
      # Creates an API Class
      #
      # @param [CreditCardAccount] CreditCardAccount
      # @return [T extends CreditCardApiBase]
      def self.create(credit_card_account)
        if credit_card_account.post_issuance?
          PostIssuance.new(credit_card_account)
        else
          PreIssuance.new(credit_card_account)
        end
      end
    end
  end
end
