require_dependency "action/accounts/fee_only_delinquent"
require_dependency "action/accounts/set_credit_bureau_flag_to_delete"
require_dependency "action/adjustments/schedule_closure_adjustment"
require_dependency "fdr_gateway/accounts/close"

module Action
  module Accounts
    class Close
      include Actionizer

      MAX_CREDIT_BUREAU_DELETE_AGE = 45.days
      DEFAULT_STATUS_REASON_CODE = "97"

      inputs_for(:call) do
        required :account_id, type: String, null: false
        optional :status_reason, type: String, values: Entity::Account::CHARGE_OFF_REASON_CODES
      end
      def call
        account = Persistence::Account.find!(id: input[:account_id])[:account]

        FdrGateway::Accounts::Close.call!(
          first_data_account_reference: account.first_data_account_reference,
          status_reason: status_reason
        )

        Adjustments::ScheduleClosureAdjustment.call!(account: account)

        if cb_delete_eligible?(account)
          SetCreditBureauFlagToDelete.call!(account: account)
        end
      end

      private

      def cb_delete_eligible?(account)
        FeeOnlyDelinquent.call!(account: account).fee_only_delinquent &&
          account.created_at > (CentralTime.now.to_date - MAX_CREDIT_BUREAU_DELETE_AGE)
      end

      def status_reason
        return input[:status_reason] if input[:status_reason]

        DEFAULT_STATUS_REASON_CODE
      end
    end
  end
end
