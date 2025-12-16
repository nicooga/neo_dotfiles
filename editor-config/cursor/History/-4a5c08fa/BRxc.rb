require_dependency "action/accounts/close"
require_dependency "action/accounts/revoke"
require_dependency "action/accounts/complete_onboarding"
require_dependency "action/accounts/delay_reissues"
require_dependency "action/accounts/get_one"
require_dependency "action/accounts/get_first_data_account_reference_mapping"
require_dependency "action/accounts/set_credit_bureau_flag_to_delete"
require_dependency "action/accounts/fee_only_delinquent"
require_dependency "action/accounts/statements_since_annual_fee_billed"
require_dependency "action/accounts/debt_management_company/batch_manage"
require_dependency "action/accounts/rewards_summary"
require_dependency "action/accounts/paginated_mapping"
require_dependency "action/accounts/get_first_data_reference"
require_dependency "action/adjustments/add_refund"
require_dependency "action/credit_cards/get_collection"
require_dependency "action/payments/get_in_flight"
require_dependency "api/setup_params"
require_dependency "api/v1/autopay_plans_api"
require_dependency "api/v1/terms_opt_out_api"
require_dependency "api/v1/credit_lines_api"
require_dependency "api/v1/credit_life_api"
require_dependency "api/v1/fraud_alerts_api"
require_dependency "api/v1/income_and_housing_api"
require_dependency "api/v1/late_fee_waivers_api"
require_dependency "api/v1/letters_api"
require_dependency "api/v1/paperless_enrollment_campaign_api"
require_dependency "api/v1/payment_accounts_api"
require_dependency "api/v1/payment_amount_strategies_api"
require_dependency "api/v1/payment_plans_api"
require_dependency "api/v1/payments_api"
require_dependency "api/v1/settings_api"
require_dependency "api/v1/statements_api"
require_dependency "api/v1/transactions_api"
require_dependency "api/v1/disaster_relief_api"
require_dependency "api/v1/mappings_api"
require_dependency "entity/refund"
require_dependency "entity/account"
require_dependency "persistence/account"
require_dependency "persistence/refund"
require_dependency "api/v1/response_models/account"
require_dependency "api/v1/response_models/accounts/onboard_complete"
require_dependency "api/v1/response_models/accounts/memo"
require_dependency "optimizely_gateway/accounts_api"

module Api
  module V1
    class AccountsApi < Grape::API
      FEATURE_DISABLED = "error.accounts_api.feature_disabled".freeze

      helpers SetupParams

      helpers do
        def warn_and_error_out!(http_code, i18n:, **i18n_args)
          message = I18n.t(i18n, **i18n_args)
          CreditCardLogger.warn("#{i18n} - #{message}")
          error!(message, http_code)
        end

        def optimizely_check!(feature_name)
          enabled = OptimizelyGateway::AccountsApi.send(
            :"#{feature_name}_enabled",
            account_id: params[:account_id]
          )[:is_enabled]

          return true if enabled

          warn_and_error_out!(
            403,
            i18n: FEATURE_DISABLED,
            feature_name: feature_name
          )
        end

        def execute_and_log(action_class, params, log_options = {})
          success = false
          result = nil

          begin
            result = action_class.call(params)
            success = result.success?

            if result.failure?
              error_message = result.error
              error!({error: error_message}, 422)
            end
          rescue => e
            success = false
            raise e
          ensure
            # Merge default log data with provided options
            log_data = {
              handled_by: "credit_card_api",
              result: success ? "accepted" : "denied"
            }.merge(log_options)

            CreditCardLogger.info(Oj.dump(log_data, mode: :compat))
          end

          result
        end
      end

      namespace :accounts do
        prefix :api
        version "v1", using: :path
        default_format :json

        before { ensure_customer_role! }

        mount AutopayPlansApi
        mount CreditLinesApi
        mount CreditLifeApi
        mount FraudAlertsApi
        mount IncomeAndHousingApi
        mount LateFeeWaiversApi
        mount LettersApi
        mount PaperlessEnrollmentCampaignApi
        mount PaymentAccountsApi
        mount PaymentAmountStrategiesApi
        mount PaymentPlansApi
        mount PaymentsApi
        mount SettingsApi
        mount StatementsApi
        mount TransactionsApi
        mount TermsOptOutApi
        mount DisasterReliefApi
        mount MappingsApi

        params do
          requires :account_id, type: String, uuid: true
          optional :with_bureau_info, type: Boolean
          optional :local_data_only, type: Boolean
          optional :with_cache, type: Boolean
        end
        route_param :account_id do
          desc "Get an account", entity: ResponseModels::Account
          get do
            parsed_params = setup_params(params)
            Tracing.trace("AccountsApi::Account", resource: request.path, **parsed_params) do |span|
              account = Action::Accounts::GetOne.call!(parsed_params)

              {account: account}
            end
          end

          desc "Update an account", entity: ResponseModels::Accounts::OnboardComplete
          post :"onboard-complete" do
            Action::Accounts::CompleteOnboarding.call!(setup_params(params))

            {message: "Onboarding successfully completed"}
          end

          desc "Get memos for actions done on this account", entity: ResponseModels::Accounts::Memo
          get :memos do
            result = Persistence::Account.memos!(account_id: setup_params(params).fetch(:account_id))

            {memos: result.memos}
          end

          desc "Update address for account"
          params do
            requires :account_id, type: String, uuid: true
            requires :address_line_one, type: String
            requires :address_line_two, type: String
            requires :city, type: String
            requires :state, type: String
            requires :zip_code, type: String
          end
          put "address" do
            Persistence::Account.update_address!(setup_params(params))

            {message: "Address updated successfully"}
          end

          desc "Delay reissues for this account's cards"
          params do
            requires :account_id, type: String, uuid: true
          end
          put "delay-reissues" do
            result = execute_and_log(
              Action::Accounts::DelayReissues,
              setup_params(params),
              {
                message: "card-reissuance-delayed",
                card_uuid: nil,
                account_uuid: params[:account_id],
                type: "delay_reissues"
              }
            )

            {message: "Reissues delayed successfully"}
          end

          desc "Revoke an account"
          params do
            requires :account_id, type: String, uuid: true
            requires :status_reason, type: String, values: Entity::Account::REVOKE_REASON_CODES
          end
          put "revoke" do
            optimizely_check! :revoke_card_workflow

            result = Action::Accounts::Revoke.call(setup_params(params))

            if result.failure?
              warn_and_error_out!(422, i18n: "error.accounts_api.put_revoke", error: result.error)
            end

            {
              message: I18n.t("message.accounts_api.put_revoke.success",
                id: params[:account_id])
            }
          end

          desc "Close an account"
          params do
            requires :account_id, type: String, uuid: true
            optional :status_reason, type: String
          end
          put "close" do
            Action::Accounts::Close.call!(setup_params(params))

            {message: "Account closed"}
          end

          desc "Check if account is fee-only delinquent"
          params do
            requires :account_id, type: String, uuid: true
          end
          get "fee-only-delinquent" do
            result = Action::Accounts::FeeOnlyDelinquent.call!(setup_params(params))

            {fee_only_delinquent: result.fee_only_delinquent}
          end

          desc "Get the number of statements since the annual fee was last billed"
          params do
            requires :account_id, type: String, uuid: true
          end
          get "statements-since-annual-fee-billed" do
            result = Action::Accounts::StatementsSinceAnnualFeeBilled.call!(setup_params(params))

            {statement_count: result.statement_count}
          end

          desc "Add a refund to an account"
          params do
            requires :account_id, type: String, uuid: true
            requires :amount_cents, type: Integer
            requires :status, type: String, values: [Entity::Refund::POSTED, Entity::Refund::PENDING]
            requires :payment_method, type: String, values: [Entity::Refund::ACH, Entity::Refund::PAPER_CHECK]
            requires :refund_type, type: String, values: Entity::Refund::REFUND_TYPES
            optional :requested_refund_id, type: Integer
          end
          post "add-refund" do
            result = Action::Adjustments::AddRefund.call!(setup_params(params))

            {refund_id: result.refund_id, adjustment_id: result.adjustment_id}
          end

          desc "Set an account's credit bureau flag to delete"
          params do
            requires :account_id, type: String, uuid: true
          end
          put "set-credit-bureau-flag-to-delete" do
            Action::Accounts::SetCreditBureauFlagToDelete.call!(setup_params(params))

            {message: "Credit bureau flag set to delete"}
          end

          desc "Set an account's external status reason code"
          params do
            requires :account_id, type: String, uuid: true
            requires :external_status_reason_code, type: String
          end
          put "set-external-status-reason-code" do
            Action::Accounts::SetExternalStatusReasonCode.call!(setup_params(params))

            {message: "External status reason code set"}
          end

          desc "Update an account's external status for added DMC"
          params do
            requires :account_id, type: String, uuid: true
          end
          put "update-status-for-added-dmc" do
            Action::Accounts::UpdateStatusForAddedDMC.call!(setup_params(params))

            {message: "External status updated for added DMC"}
          end

          desc "Get rewards summary on this account"
          get "rewards/summary" do
            result = Action::Accounts::RewardsSummary.call!(account_id: setup_params(params).fetch(:account_id))

            {rewards_summary: result.rewards_summary}
          end
        end

        desc "Mapping of account uuid to First Data Account Reference"
        params do
          requires :s3_key, type: String
        end
        post "first-data-account-reference-mapping" do
          result = Action::Accounts::GetFirstDataAccountReferenceMapping.call!(s3_key: params[:s3_key])

          {message: "Mapping written to S3", location: result.location}
        end

        desc "Batch set charge off reason code for accounts"
        params do
          requires :account_ids, type: [String]
          requires :reason_code, type: String, values: Entity::Account::CHARGE_OFF_REASON_CODES
        end

        post "set-charge-off-reason-code" do
          Action::Accounts::SetChargeOffReasonCode.call!(setup_params(params))

          {message: "Successfully queued charge off file"}
        end

        desc "Batch adding debt management company to non-active accounts"
        params do
          requires :account_ids, type: [String]
        end
        post "batch-add-debt-management-company" do
          file_id = Action::Accounts::DebtManagementCompany::BatchManage.call!(
            setup_params(params).merge(action: :add)
          )

          {message: "Successfully queued adding debt management company file", file_id: file_id}
        end

        desc "Batch removing debt management company from active accounts"
        params do
          requires :account_ids, type: [String]
        end
        post "batch-remove-debt-management-company" do
          file_id = Action::Accounts::DebtManagementCompany::BatchManage.call!(
            setup_params(params).merge(action: :remove)
          )

          {message: "Successfully queued removing debt management company file", file_id: file_id}
        end

        # Namespace trick in order to authorize for a service role
        namespace do
          before { ensure_service_role! }

          desc "Gets all account ids with in-flight payments."
          params do
            optional :account_ids,
              type: [String],
              documentation: {description: "Optional. Account ids to filter payments by"}
          end
          post :"payments-in-flight" do
            result = Action::Payments::GetInFlight.call(setup_params(params))

            if result.success?
              status 200
              # Returning only account_ids in order to keep payload small
              {account_ids: result.payments.map(&:account_id).uniq}
            else
              CreditCardLogger.warn("FAIL! - #{result.error}")
              error!({errors: result.error}, 422)
            end
          end

          desc "Bulk get payments for a list of account ids and look back window"
          params do
            requires :account_ids, type: [String]
            optional :look_back_days, type: Integer
          end
          post :"payments-bulk" do
            parsed_params = setup_params(params)
            Tracing.trace("AccountsApi::GetPaymentsBulk", resource: request.path, **parsed_params) do |span|
              result = Action::Payments::GetPaymentsBulk.call(parsed_params)

              if result.success?
                status 200
                {payments: result.payments}
              else
                Tracing.add_context(error: true, error_message: result.error)
                CreditCardLogger.warn("FAIL! - #{result.error}")
                error!({errors: result.error}, 422)
              end
            end
          end

          desc "Get first_data_account_reference for a specific account"
          params do
            requires :account_uuid, type: String, uuid: true
          end
          get ":account_uuid/first_data_account_reference" do
            result = Action::Accounts::GetFirstDataReference.call(
              account_uuid: params[:account_uuid]
            )

            if result.success?
              status 200
              result.value
            else
              case result.error_reason
              when Entity::NOT_FOUND
                error!({error: result.error}, 404)
              when Entity::UNPROCESSABLE
                error!({error: result.error}, 422)
              else
                # Raise StandardError for unexpected errors - will be caught by
                # root_api.rb handler which logs to Sentry and returns 500
                raise StandardError, result.error
              end
            end
          end
        end
      end
    end
  end
end
