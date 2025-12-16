require_dependency "fdr_gateway/base"

module FdrGateway
  module Accounts
    class IssueLetter < FdrGateway::Base
      include Actionizer

      inputs_for(:call) do
        required :first_data_account_reference, type: String, null: false
        required :letter_id, type: String, null: false
      end

      def call
        fdr_gateway_call("issue-letter_account", message_params)
      end

      def message_params
        {
          letter_id: input[:letter_id],
          first_data_account_reference: input[:first_data_account_reference]
        }
      end
    end
  end
end
