require_dependency "fdr_gateway/base"

module FdrGateway
  module Accounts
    class Get < FdrGateway::Base
      inputs_for(:call) do
        required :account_reference, type: String
        optional :existing_card_references, default: []
        optional :with_bureau_info, default: false
      end
      def call
        output[:account] = fdr_gateway_call(
          "get_account",
          account_reference: input[:account_reference],
          existing_card_references: input[:existing_card_references],
          with_bureau_info: input[:with_bureau_info]
        ).fetch(:account)
      end
    end
  end
end
