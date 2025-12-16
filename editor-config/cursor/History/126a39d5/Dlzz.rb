require_dependency 'rest_api'

# https://devcenter.firstdata.com/org/usapi/docs/api#maintenance-v2-initiatecreditlineactions
module FdrGateway
  module Accounts
    class GetCreditLineDecision
      include Actionizer

      # Yes, really CREDT LINE without the I
      CREDIT_LINE = 'CREDT LINE'
      LETTER_NUM = 'LETTER NUM'
      ACTION_NUM = 'ACTION NUM'
      STRATEGY_NUM = 'STRAT NMBR'
      STRATEGY_LINE = 'STRAT LINE'

      inputs_for :call do
        required :first_data_account_reference, type: String, null: false
      end
      # rubocop:disable Metrics/MethodLength, Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
      def call
        result = RestApi.call!(
          path: '',
          account_id: input.first_data_account_reference,
          json_params: {
            reviewIndicator: 'Y'
          }
        ).body.deep_symbolize_keys

        payload = {
          declined: true,
          credit_line_amount: nil,
          letter: nil,
          strategy_line: nil,
          strategy_number: nil,
          action_number: nil
        }

        result[:actions].each do |action|
          if action[:elementName] == CREDIT_LINE
            payload[:declined] = false
            payload[:credit_line_amount] = action[:elementValueText]&.strip&.tr(',', '')&.to_i
          end

          if action[:elementName] == LETTER_NUM
            payload[:letter] = letter_mapping(action[:elementValueText]&.strip)
          end

          if action[:elementName] == ACTION_NUM
            payload[:action_number] = action[:elementValueText]&.strip
          end

          if action[:elementName] == STRATEGY_NUM
            payload[:strategy_number] = action[:elementValueText]&.strip
          end

          if action[:elementName] == STRATEGY_LINE
            payload[:strategy_line] = action[:elementValueText]&.strip
          end
        end

        output.payload = payload
      end
      # rubocop:enable Metrics/MethodLength, Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity

      private

      # TOTALLY_NOT_TODO: implement mapping to
      # sane values when we get that info from business
      def letter_mapping(letter)
        letter
      end
    end
  end
end
