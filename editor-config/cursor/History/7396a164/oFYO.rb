module Action
    module Accounts
        # TODO: remove or this comment
        # This action's objective is to determine if an account is eligible for an AMF refund.
        # In order to do that we need to check that:
        # - has an AMF product and has paid the AMF
        # - has not made a purchase
        # - has not made a cash advance
        class IsEligibleForAmfRefund
            include Actionizer

            DISQUALIFYING_POSTED_TYPES = ["Purchase", "Cash Advance", "Cash"].freeze
            DISQUALIFYING_PENDING_TYPES = ["Purchase", "Cash Advance"].freeze

            inputs_for(:call) do
                required :account, type: Entity::Account
            end

            def call
                output[:is_elegible_for_amf_refund] = eligible_for_amf_refund?
            end

            private

            def eligible_for_amf_refund?
                return false unless has_amf_product?
                return false unless has_paid_amf?
                return false if has_posted_disqualifying_transactions?
                true
            end

            def has_amf_product?
                input[:account].annual_fee_cents.to_i.positive?
            end

            def has_paid_amf?
                input[:account].unpaid_annual_charge_amount.to_i.zero?
            end
            def has_posted_disqualifying_transactions?
                posted_transactions.any? { |t| DISQUALIFYING_POSTED_TYPES.include?(t.type_display) }
            end

            def posted_transactions
                Persistence::Transaction.past_posted!(account_id: input[:account].id)
                + Persistence::Transaction.cycle_posted!(account_id: input[:account].id)
            end
        end
    end
end