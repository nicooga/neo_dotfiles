require_dependency "action/emails/credit_line_increase_noaa_time_on_books"
require_dependency "persistence/credit_line_modification_request"
require_dependency "entity/credit_line_modification_request"

module Action
  module Accounts
    class IncreaseCreditLine
      include Actionizer

      inputs_for(:call) do
        required :account_id, null: false
      end
      def call
        Persistence::CreditLineModificationRequest.create!(
          account_id: input[:account_id],
          request_type: Entity::CreditLineModificationRequest::TYPE_INCREASE,
          outcome: Entity::CreditLineModificationRequest::OUTCOME_DECLINE,
          decline_reason: Entity::CreditLineModificationRequest::DECLINE_REASON_NOT_ACCEPTING_APPLICATIONS
        )
      end
    end
  end
end
