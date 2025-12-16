require_dependency 'base_client'
require_dependency 'constants'

module FdrGateway
  module Accounts
    class IssueLetter < BaseClient
      def call
        message = message(input.first_data_account_reference, input.letter_id)

        make_client_call(message, input.first_data_account_reference)
      end

      # Overrides method in BaseClient to include fdr_error_code in downstream error
      def make_client_call(message, generic_id, retry_call = true)
        response = client.call(operation, message: message, soap_header: security_header)

        if response_considered_success?(response)
          return response
        end

        if retry_call
          begin
            return make_client_call(message, generic_id, false)
          rescue Actionizer::Failure => e
            log_and_capture_error(message, response.body.to_s)
            fail!(error: e.message, response_status: response_status)
          end
        end

        fail!(error: failure_message, response_status: response_status)
      end

      # Overrides method in BaseClient
      def response_considered_success?(response)
        if !response.success?
          return false
        end

        response_message = response.body.dig(:issue_letter_response_element, :response_message)
        @last_fdr_error_code = response_message&.dig(:result_message_code)

        @last_fdr_error_code == SUCCESS_MESSAGE_CODE
      end

      # Overrides method in BaseClient
      def response_status
        Constants.unprocessable_entity
      end

      private

      def failure_message
        msg = "FdrGateway call to #{action} failed"
        msg += " (fdr_error_code: #{@last_fdr_error_code})" if @last_fdr_error_code
        msg
      end

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
