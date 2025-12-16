module Action
  module Accounts
    class IsEligibleForAmfRefund
      include Actionizer

      DISQUALIFYING_TYPES = ["Purchase", "Cash Advance", "Cash"].freeze

      inputs_for(:call) do
        required :account, type: Entity::Account
      end

      def call
        output[:is_eligible_for_amf_refund] = eligible_for_amf_refund?
      end

      private

      def eligible_for_amf_refund?
        has_amf_product?
        && !has_paid_amf?
        && !has_posted_disqualifying_transactions?
      end

      def has_amf_product?
        input[:account].annual_fee_cents.to_i.positive?
      end

      def has_paid_amf?
        input[:account].unpaid_annual_charge_amount.to_i < input[:account].annual_fee_cents.to_i
      end

      def has_posted_disqualifying_transactions?
        posted_transactions.any? { |t| DISQUALIFYING_TYPES.include?(t.type_display) }
      end

      def posted_transactions
        @posted_transactions ||= begin
          Persistence::Transaction.past_posted!(account_id: input[:account].id) +
          Persistence::Transaction.cycle_posted!(account_id: input[:account].id)
        end
      end
    end
  end
end