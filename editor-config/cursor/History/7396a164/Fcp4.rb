module Action
    module Accounts
        # TODO: remove or this comment
        # This action's objective is to determine if an account is eligible for an AMF refund.
        # In order to do that we need to check that:
        # - has an AMF product and has/ has not paid the AMF
        # - has/ has not made a purchase
        # - has/ has not made a cash advance
        # - what happens on the first cycle. Is # of purchases available in Fiserv etc?
        class IsEligibleForAmfRefund
            include Actionizer

            inputs_for(:call) do
                required :account_account, type: Entity::Account
            end

            def call
                output[:is_elegible_for_amf_refund] = eligible_for_amf_refund?
            end

            private

            def eligible_for_amf_refund?
                return false unless has_amf_product?
                return false unless has_paid_amf?
                return false unless has_made_purchase?
                return false unless has_made_cash_advance?
                return false unless has_first_cycle?
                true
            end

            def has_amf_product?
            end

            def set_result(result)
            end
        end
    end
end