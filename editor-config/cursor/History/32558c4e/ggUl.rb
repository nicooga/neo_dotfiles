require_relative 'base'

module Admin
  module V2
    module Workflow
      module Product
        # This class represents an error when calling the CreditCard API to revoke 
        # the account
        class RevokeAccountApiError < Amount::Event::ErrorWithContext; end

        class RevokeAccount < Admin::V2::Workflow::Product::Base
          state [:product_id, :product_type, :status_reason_code]

          TITLE = 'Revoke Account'.freeze
          CATEGORY = 'product'.freeze
          PERMISSION = :can_manage_fraud_escalations

          REASON_CODES = [
            ['E60 - Closed account due to confirmed credit abusive behavior', '60'],
            ['E59 - Closed account due to application fraud', '59'],
            ['E58 - Denied identity theft claim', '58'],
            ['E57 - Denied bad faith fraudulent transaction claim', '57'],
          ].freeze

          class << self
            def show_to?(target)
              # We use the feature flag revoke_card_workflow to know if we need to show the
              # workflow or not
              # TODO: once this feature is fully deployed and approve we need to remove the feature flag
              target.is_a?(::CreditCardAccount) && target.revoke_card_workflow_enabled?
            end

            def credit_card_permissions
              @credit_card_permissions ||= {
                pre_issuance:  false,
                post_issuance: true
              }.freeze
            end

            def status_reason_codes
              [['Select an Option', '']] + REASON_CODES
            end
          end

          ### START WORKFLOW ###

          step :start do
            script :start

            input :status_reason_code, required: true, type: :select, values: status_reason_codes

            action :continue do
              next_step :confirmation
            end
          end

          step :confirmation do
            script :confirmation

            action :yes do
              revoke_account_response = product.api.revoke_account(status_reason: @state[:status_reason_code]) 
              
              if revoke_account_response.success?
                @state[:error_closing_account] = false
                generate_note
              else
                @state[:error_closing_account] = true
                Amount::Event::Alert.error(
                  RevokeAccountApiError.new(
                    "Error revoking credit card account: #{product.id}",
                    error: revoke_account_response.failure
                  )
                )
              end

              next_step :end
            end

            action :no do
              next_step :end
            end
          end

          step :end do
            script -> { finish_result_script }
          end

          private

          def finish_result_script
            @state[:error_closing_account] ? :unable_to_revoke_account : :finish
          end

          def generate_note
            create_note!(
              type:     'Fraud Team',
              activity: 'Escalation',
              action:   'Response',
              text:     REASON_CODES.find { |rc| rc[1] == state[:status_reason_code] }.try(:[], 0)
            )
          end
        end
      end
    end
  end
end
