require_dependency "fdr_gateway/base"

module FdrGateway
  module Accounts
    class GetCreditLineDecision < FdrGateway::Base
      include Actionizer

      inputs_for(:call) do
        required :first_data_account_reference, type: String, null: false
      end
      def call
        output[:decision] = fdr_gateway_call(
          "get_credit_line_decision",
          first_data_account_reference: input[:first_data_account_reference]S
        ).fetch(:credit_line_decision)
      end
    end
  end
end
