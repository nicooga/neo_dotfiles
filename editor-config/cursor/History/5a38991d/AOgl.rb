require_relative "base"
require_relative "opt_out_of_change_in_terms"

module Admin
  module V2
    module Workflow
      module Product
        class CloseCreditCardAccount < Admin::V2::Workflow::Product::Base
          include Admin::V2::Workflow::Shared::Redirect
          include Admin::V2::Workflow::Shared::CreditCardAccount

          state %i[product_id product_type account_closure_reason other_account_closure_reason error_closing_account account_closure_script]

          TITLE = "Close Credit Card Account".freeze
          CATEGORY = "product".freeze
          PERMISSION = :can_terminate_credit_card
          TRADELINE_REPORTING_EXEMPTION_PERIOD = 45

          CLOSURE_REASONS = [
            ["APR Too High", "apr_too_high"],
            ["Better Card Offer", "better_card_offer"],
            ["Card Declined", "card_declined"],
            ["Card Not Received", "card_not_received"],
            ["Change In Terms", "change_in_terms"],
            ["Credit Limit Too Low", "credit_limit_too_low"],
            ["Fraudulent Activity", "fraudulent_activity"],
            ["Fees Too High", "fees_too_high"],
            ["No Longer Needed", "no_longer_needed"],
            ["Other", "other"]
          ].freeze

          class << self
            def show_to?(target)
              target.is_a?(::CreditCardAccount) && closeable_status?(target)
            rescue => e
              Amount::Event::Alert.error(e)
              false
            end

            def credit_card_permissions
              @credit_card_permissions ||= {
                pre_issuance: false,
                post_issuance: true
              }.freeze
            end

            def closeable_status?(target)
              ["A", " "].include?(target.account["account_external_status"])
            end
          end

          private_class_method :closeable_status?

          # Return current balance in cents, using the credit card account
          # object obtained from Credit Card API
          #
          # @return [Integer]
          def current_balance_cents
            external_credit_card_account['current_balance_cents']
          end

          # Return annual fee in cents, using the credit card account
          # object obtained from Credit Card API
          #
          # @return [Integer]
          def annual_fee_cents
            external_credit_card_account['annual_fee_cents']
          end

          def annual_fee
            humanized_money_with_symbol(Money.new(annual_fee_cents))
          end

          def account_closure_reasons
            [["Select an Option", ""]] + closure_reasons
          end

          def closure_reasons
            CLOSURE_REASONS
          end

          ### START WORKFLOW ###

          step :start do
            script :start
            input :account_closure_reason, required: true, type: :select, values: -> { account_closure_reasons }

            action :next do
              if @state[:account_closure_reason] == "other"
                next_step :other
              else
                go_to_account_closure_step
              end
            end
          end

          step :other do
            script :other
            input :other_account_closure_reason, type: :textarea, required: true, placeholder: "Reason for closing account", maxlength: 255

            action :next do
              go_to_account_closure_step
            end
          end

          step :close_account do
            script -> { @state[:account_closure_script] }

            action :yes do
              if product.api.close_account.success?
                execute_closing_steps
              else
                @state[:error_closing_account] = true
              end
              next_step :end
            end

            action :no do
              @state[:error_closing_account] = false
              next_step :end
            end
          end

          step :end do
            script -> { final_result_script }
          end

          private

          def generate_note
            create_note!(
              type: "Credit Card - Inbound Servicing",
              activity: "Close Account",
              action: closure_reasons.find { |cr| cr[1] == state[:account_closure_reason] }.try(:[], 0),
              text: state[:other_account_closure_reason]
            )
          end

          def external_credit_card_account
            @external_credit_card_account ||= product.account
          end

          def should_set_credit_bureau_flag_to_delete?
            fee_only_delinquent? && external_credit_card_account["open_date"].to_date > Date.current - TRADELINE_REPORTING_EXEMPTION_PERIOD.days
          end
        end
      end
    end
  end
end
