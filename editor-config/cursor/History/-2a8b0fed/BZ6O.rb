require_dependency 'base_client'
require_dependency 'constants'

module FdrGateway
  module Accounts
    class IssueLetter < BaseClient
      def call
        message = message(input.first_data_account_reference, input.letter_id)

        make_client_call(message, input.first_data_account_reference)
      end

      # Overrides method in BaseClient
      def response_considered_success?(response)
        if !response.success?
          return false
        end

        response_message = response.body.dig(:issue_letter_response_element, :response_message)
        result_message_code = response_message&.dig(:result_message_code)

        if result_message_code != SUCCESS_MESSAGE_CODE
          # Log only the numeric error code (safe, no PII)
          # Note: result_message may contain PII - do not log without verification
          Rails.logger.error("IssueLetter failed - result_code: #{result_message_code}")
          return false
        end

        true
      end

      # Overrides method in BaseClient
      def response_status
        Constants.unprocessable_entity
      end

      private

      def namespace
        'IssueLetter'
      end

      def action
        'IssueLetter'
      end

      def message(first_data_account_reference, letter_id)
        {
          "#{wsdl_namespace}:AccountId" => first_data_account_reference,
          "#{wsdl_namespace}:LetterId" => letter_id
        }
      end
    end
  end
end
