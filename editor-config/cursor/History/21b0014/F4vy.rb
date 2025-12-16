require_dependency "action/credit_line_increases/validate"
require_dependency "action/credit_line_increases/send_request"
require_dependency "entity/credit_line_increase_request"
require_dependency "persistence/credit_line_increase_request"

module Action
  module CreditLineIncreases
    class RequestIncrease
      include Actionizer

      # @!method self.call(args)
      #   @param args [Hash] the input for the action
      #   @option args [Entity::Account] :account An optional account that is used to calculate the 
      #     monthly net income
      #   @option args [String] :account_id An optional account_id used to locate the account that
      #       is going to be used to calculate the monthly net income
      #   @note If account is provided that is going to be used, otherwise we try to find the account
      #     using account_id argument
      #   @return [Actionizer::Result] an result containing a key  credit_line_increase
      inputs_for(:call) do
        required :monthly_net_income_cents, null: false, type: Integer
        required :monthly_housing_expense_cents, null: false, type: Integer
        required :income_and_housing_id, null: false, type: String
        required :reason, null: false, type: String
        required :origin, null: false, type: String
        optional :account
        optional :account_id
      end

      # Implementation of {.call}
      def call
        validate_result = CreditLineIncreases::Validate.call(account_id: account.id)

        process_result!(validate_result)
      end

      private

      def process_result!(validate_result)
        case validate_result
        in success:, **_
          credit_line_increase_request = create_credit_line_increase_request!(status: Entity::CreditLineIncreaseRequest::STATUS_REQUESTED)

          credit_line_increase = CreditLineIncreases::SendRequest.call!(
            credit_line_increase_request: credit_line_increase_request,
            monthly_net_income_cents: input[:monthly_net_income_cents],
            monthly_housing_expense_cents: input[:monthly_housing_expense_cents],
            retry: false
          ).credit_line_increase

          output[:credit_line_increase] = credit_line_increase
        in failure:, error_code: ErrorCodeFailure::CREDIT_LINE_CANNOT_REQUEST_ON_COOLDOWN, **rest  
          decision = create_credit_line_increase_decision!
          create_credit_line_increase_request!(
            status: Entity::CreditLineIncreaseRequest::STATUS_DECLINED,
            credit_line_increase_decision_id: decision.id
          )
        
          fail!({error_code: ErrorCodeFailure::CREDIT_LINE_CANNOT_REQUEST_ON_COOLDOWN}.merge(rest))
        in failure:, **context 
          fail!(**context)
        end
      end

      def account
        @account ||= input[:account] || Persistence::Account.find!(id: input[:account_id])[:account]
      end

      def create_credit_line_increase_decision!
        decision = Persistence::CreditLineIncreaseDecision.create!(
          decline_reason: Entity::CreditLineIncreaseRequest::REASON_COOLDOWN,
          declined: true
        ).credit_line_increase_decision
      end

      def create_credit_line_increase_request!(status:, credit_line_increase_decision_id: nil)
        attrs = {
          account_id: account.id,
          status: status,
          income_and_housing_id: input[:income_and_housing_id],
          valid_income: true,
          request_reason: input[:reason],
          origin: input[:origin],
          starting_credit_line_amount_cents: account.credit_limit_cents,
          ending_credit_line_amount_cents: account.credit_limit_cents,
        }
        attrs.merge!({
          credit_line_increase_decision_id: credit_line_increase_decision_id,
        }) if credit_line_increase_decision_id.present?

        Persistence::CreditLineIncreaseRequest.create!(attrs).credit_line_increase_request
      end
    end
  end
end
