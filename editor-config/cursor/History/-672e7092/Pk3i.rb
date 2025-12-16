require_dependency "action/accounts/issue_letter"
require_dependency "action/credit_line_increases/get_decision"
require_dependency "action/credit_line_increases/update_credit_limit"
require_dependency "action/credit_line_increases/update_credit_report_info"
require_dependency "action/credit_line_increases/fraud_alerts_check"
require_dependency "persistence/credit_line_increase_request"
require_dependency "persistence/account"
require_dependency "entity/credit_line_increase_request"
require_dependency "action/emails/credit_line_increase_retry_declined"
require_dependency "optimizely_gateway/credit_line_increases"

module Action
  module CreditLineIncreases
  # This class orchestrates the processing of a credit line increase request,
  # including eligibility checks, credit report updates, decision making,
  # and execution of associated side-effects such as updating credit limits,
  # handling declines, and issuing notifications.
    class SendRequest
      include Actionizer

      inputs_for(:call) do
        required :credit_line_increase_request, null: false, type: Entity::CreditLineIncreaseRequest
        required :monthly_net_income_cents, null: false, type: Integer
        required :monthly_housing_expense_cents, null: false, type: Integer
        required :retry, null: false
      end

      def call
        unless eligible?
          fail!(ErrorCodeFailure.create(ErrorCodeFailure::CREDIT_LINE_INCREASE_HAS_INVALID_STATUS))
        end

        credit_report = UpdateCreditReportInfo.call!(
          credit_line_increase: input[:credit_line_increase_request],
          monthly_net_income_cents: input[:monthly_net_income_cents],
          monthly_housing_expense_cents: input[:monthly_housing_expense_cents]
        ).credit_report

        decision_result = GetDecision.call!(account_id: account_id, credit_report: credit_report)

        if decision_result.decision.declined
          decline!(letter_id: decision_result.decision.letter)
        end

        # Check for TransUnion fraud alerts if feature flag is enabled
        check_fraud_alerts_if_enabled!

        UpdateCreditLimitWorker.perform_async(
          account_id: account_id,
          credit_line_increase_request_id: decision_result.credit_line_increase.id
        )

        output[:credit_line_increase] = decision_result.credit_line_increase
      end

      private

      def eligible?
        if input[:retry]
          return [
            Entity::CreditLineIncreaseRequest::STATUS_FDR_FAILED,
            Entity::CreditLineIncreaseRequest::STATUS_CREDIT_REPORT_RECEIVED,
            Entity::CreditLineIncreaseRequest::STATUS_REQUESTED
          ].include?(input[:credit_line_increase_request].status)
        end

        input[:credit_line_increase_request].status == Entity::CreditLineIncreaseRequest::STATUS_REQUESTED
      end

      def account_id
        input[:credit_line_increase_request].account_id
      end

      def decline!(letter_id:)
        letter_result = Action::Accounts::IssueLetter.call(
          account_id: account_id,
          letter_id: letter_id
        )

        if letter_result.failure?
          IssueLetterWorker.perform_in(
            30.minutes,
            account_id: account_id,
            letter_id: letter_id
          )

          fail!(error: I18n.t("error.credit_line_increase.first_data_noaa_failure"))
        end

        if input[:retry]
          Emails::CreditLineIncreaseRetryDeclined.deliver!(
            account_id: account_id
          )
        end

        Persistence::CreditLineIncreaseRequest.update!(
          id: input[:credit_line_increase_request].id,
          noaa_sent_at: CentralTime.now
        )

        fail!(ErrorCodeFailure.create(ErrorCodeFailure::CREDIT_LINE_INCREASE_DECLINED))
      end

      # Check for TransUnion fraud alerts if the feature flag is enabled.
      # Declines the credit line increase request if fraud alerts are detected.
      #
      # @return [void]
      # @raise [Actionizer::Failure] if fraud alerts are present
      def check_fraud_alerts_if_enabled!
        return unless fraud_alerts_enabled?

        fraud_check_result = FraudAlertsCheck.call!(
          customer_uuid: customer_uuid,
          correlation_id: correlation_id
        )

        return unless has_fraud_alerts?(fraud_check_result.fraud_alerts)

        # Update request status to declined
        Persistence::CreditLineIncreaseRequest.update!(
          id: input[:credit_line_increase_request].id,
          status: Entity::CreditLineIncreaseRequest::STATUS_DECLINED
        )

        fail!(ErrorCodeFailure.create(ErrorCodeFailure::CREDIT_LINE_INCREASE_DECLINED))
      end

      # Determine if fraud alerts feature flag is enabled for this customer.
      #
      # @return [Boolean] true if fraud alerts check should be performed
      def fraud_alerts_enabled?
        OptimizelyGateway::CreditLineIncreases
          .fraud_alerts_enabled(customer_uuid: customer_uuid)
          .is_enabled
      end

      # Check if the fraud alerts response contains any military or fraud alert flags.
      # Checks for: active_duty (military/SCRA), initial_fraud, extended_fraud
      #
      # @param fraud_alerts_data [Hash] the fraud alerts response data with boolean flags
      # @return [Boolean] true if any fraud alert flags are true
      def has_fraud_alerts?(fraud_alerts_data)
        return false unless fraud_alerts_data

        fraud_alerts_data[:active_duty] == true ||
          fraud_alerts_data[:initial_fraud] == true ||
          fraud_alerts_data[:extended_fraud] == true
      end

      # Get the customer UUID from the credit line increase request's account.
      #
      # @return [String] the customer UUID
      def customer_uuid
        @customer_uuid ||= Persistence::Account.local_find!(id: account_id).account.customer_id
      end

      # Generate a correlation ID for tracking the fraud alerts request.
      #
      # @return [String] correlation ID
      def correlation_id
        @correlation_id ||= SecureRandom.uuid
      end
    end
  end
end
