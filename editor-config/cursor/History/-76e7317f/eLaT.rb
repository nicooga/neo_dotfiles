require_dependency "action/accounts/update_credit_bureau_score"
require_dependency "entity/credit_line_increase_request"
require_dependency "entity/credit_report"
require_dependency "fdr_gateway/accounts/get_credit_line_decision"
require_dependency "fdr_gateway/accounts/update_valid_income"
require_dependency "fdr_gateway/accounts/update_ability_to_pay_max_credit_line"
require_dependency "persistence/account"
require_dependency "persistence/customer"
require_dependency "persistence/credit_line_increase_request"
require_dependency "persistence/credit_line_increase_decision"

module Action
  module CreditLineIncreases
    class GetDecision
      include Actionizer

      VALID_LINE_TIERS = [
        300, 400, 500, 600, 750, 1000, 1250, 1500, 2000, 2500, 3000
      ]

      inputs_for(:call) do
        required :account_id, type: String, null: false
        required :credit_report, type: Entity::CreditReport, null: false
      end
      def call
        decision = create_credit_line_increase_decision

        output[:credit_line_increase] =
          if fdr_decision_result[:declined]
            Persistence::CreditLineIncreaseRequest.update!(
              id: matching_request.id,
              status: Entity::CreditLineIncreaseRequest::STATUS_DECLINED,
              credit_line_increase_decision_id: decision.id
            ).credit_line_increase_request
          else
            unless VALID_LINE_TIERS.include?(fdr_decision_result[:credit_line_amount])
              fail!(
                error: I18n.t(
                  "error.credit_line_increase.amount_not_in_policy",
                  credit_line_amount: fdr_decision_result[:credit_line_amount]
                )
              )
            end

            Persistence::CreditLineIncreaseRequest.update!(
              id: matching_request.id,
              status: Entity::CreditLineIncreaseRequest::STATUS_APPROVED,
              ending_credit_line_amount_cents: fdr_decision_result[:credit_line_amount] * 100,
              credit_line_increase_decision_id: decision.id
            ).credit_line_increase_request
          end

        output[:decision] = OpenStruct.new(fdr_decision_result)
      end

      private

      def account
        @account ||= begin
          result = Persistence::Account.find(id: input[:account_id])

          if result.failure?
            fail_update!(result.error)
          end

          result.account
        end
      end

      def create_credit_line_increase_decision
        decline_reason = if fdr_decision_result[:declined]
          Entity::CreditLineIncreaseRequest::REASON_FIRST_DATA_DECLINED
        end

        Persistence::CreditLineIncreaseDecision.create!(
          approved_amount: fdr_decision_result[:credit_line_amount],
          letter: fdr_decision_result[:letter],
          declined: fdr_decision_result[:declined],
          strategy_number: fdr_decision_result[:strategy_number],
          strategy_line: fdr_decision_result[:strategy_line],
          action_number: fdr_decision_result[:action_number],
          decline_reason: decline_reason
        ).credit_line_increase_decision
      end

      def matching_request
        @matching_request ||= Persistence::CreditLineIncreaseRequest.matching_request!(
          account_id: input[:account_id],
          status: Entity::CreditLineIncreaseRequest::STATUS_CREDIT_REPORT_RECEIVED
        ).credit_line_increase_request
      end

      def fdr_decision_result
        @fdr_decision_result ||=
          begin
            first_data_results = []

            first_data_results << Action::Accounts::UpdateCreditBureauScore.call(
              first_data_account_reference: account.first_data_account_reference,
              credit_bureau_date: account.credit_bureau_date,
              score: matching_request.credit_score,
              reason_codes: input[:credit_report].credit_score_reasons
            )

            decision_result = FdrGateway::Accounts::GetCreditLineDecision.call(
              first_data_account_reference: account.first_data_account_reference
            )

            first_data_results << decision_result

            if (failure = first_data_results.find { |r| r&.failure? })
              fail_update!(failure.error)
            else
              decision_result.decision
            end
          end
      end

      def fail_update!(error)
        Persistence::CreditLineIncreaseRequest.update!(
          id: matching_request.id,
          status: Entity::CreditLineIncreaseRequest::STATUS_FDR_FAILED
        )

        fail!(error: I18n.t("error.credit_line_increase.first_data_update_failed", message: error))
      end
    end
  end
end
