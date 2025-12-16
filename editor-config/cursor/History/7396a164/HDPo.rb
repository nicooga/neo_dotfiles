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
                return false if has_made_purchase?
                return false if has_made_cash_advance?
                true
            end

            def has_amf_product?
                input[:account].annual_fee_cents.to_i.positive?
            end

            def has_paid_amf?
                input[:account].unpaid_annual_charge_amount.to_i.positive?
            end

            def has_made_purchase?
            end

            def has_made_cash_advance?
            end

            def has_first_cycle?
            end

            def set_result(result)
            end
        end
    end
end