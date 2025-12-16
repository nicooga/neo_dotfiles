require_dependency "api/validations/uuid"
require_dependency "action/accounts/increase_credit_line"
require_dependency "action/credit_line_increases/request_increase"
require_dependency "action/credit_line_increases/validate"
require_dependency "api/v1/response_models/credit_lines/request_increase"

module Api
  module V1
    class CreditLinesApi < Grape::API
      helpers SetupParams

      class CreditLineIncreaseError < RuntimeError; end

      params do
        requires :account_id, type: String, uuid: true
      end
      route_param :account_id do
        resource :'credit-lines' do
          desc "Request an increase to the credit limit on your account",
            entity: ResponseModels::CreditLines::RequestIncrease
          post :'request-increase' do
            result = Action::Accounts::IncreaseCreditLine.call(setup_params(params))

            if result.success?
              {message: "Successfully requested credit line increase."}
            else
              # This can only happen if the database is down somehow.
              error = CreditLineIncreaseError.new(
                "Unable to handle credit line increase request for Account #{params["account_id"]}. \
                Details: #{result.error}"
              )
              CreditCardLogger.error(error)
              error!(I18n.t("error.credit_lines.couldnt_increase"), 422)
            end
          end

          desc "Validates that customer can make a credit line increase request"
          post :validate do
            result = Action::CreditLineIncreases::Validate.call(
              setup_params(params).merge(
                skip_cooldown_check: true
              )
            )

            if result.success?
              status 200
              {message: "Customer can make credit line increase request"}
            else
              CreditCardLogger.warn("FAIL! - #{result.error}")
              error!({error: result.error, error_code: result.error_code}, 422)
            end
          end

          desc "The real way to request a credit line increase"
          params do
            requires :monthly_net_income_cents, type: Integer
            requires :monthly_housing_expense_cents, type: Integer
            requires :income_and_housing_id, type: String
            requires :reason, type: String
            requires :origin, type: String
          end
          post :request do
            result = Action::CreditLineIncreases::RequestIncrease.call(setup_params(params))

            if result.success?
              status 200
              {credit_line_increase: result.credit_line_increase}
            else
              CreditCardLogger.warn("FAIL! - #{result.error}")
              error!({error: result.error, error_code: result.error_code}, 422)
            end
          end
        end
      end
    end
  end
end
