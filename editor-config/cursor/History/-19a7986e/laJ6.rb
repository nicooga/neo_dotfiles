# frozen_string_literal: true

require './platforms/account_opening/api/system/application/generic_create_application'
require './platforms/account_management/api/consumer/credit_card_account/activate_card'
require_relative '../../models/admin/v2/workflow/product/activate_card'

module AccountOpening
  class CreditCardController < FrontendController
    class InvalidPolicyError < StandardError; end

    class MissingCreditCardError < Amount::Event::ErrorWithContext; end
    class SSNMismatchError < Amount::Event::ErrorWithContext; end

    # Import constants from related classes
    GENERIC_ERROR_MESSAGE = ::Admin::V2::Workflow::Product::ActivateCard::GENERIC_ERROR_MESSAGE

    before_action { not_found unless Avant::Env.cc_g2_enabled? }
    before_action { visit_tracker.track! :enter_site }

    def apply
      redirect_to '/credit-card/'
    end

    def activate
      dash_url = Avant::Env.ip_dash_url
      dash_url += '/' unless dash_url.end_with?('/')
      redirect_to "#{dash_url}activate-card", status: :moved_permanently
    end

    # rubocop:disable Metrics/MethodLength
    def activate_card
      email = params[:email]
      unless email.is_a?(String)
        return render_bad_request('Email provided must be a String', 'email')
      end

      customer = Customer.find_by(email: email.downcase)
      unless customer
        return render_bad_request("Can't find customer with the email: #{email.downcase}", 'email')
      end

      credit_card_account = customer.credit_card_accounts.find do |cc_account|
        next false unless cc_account.issued?

        cc_account.api.account.credit_cards.any? { |cc| cc['last_four'] == request[:card_last_4] }
      end
      unless credit_card_account
        Amount::Event::Alert.warn(
          MissingCreditCardError.new(
            'Unable to find CreditCardAccount in activate_card',
            last_4: request[:card_last_4]
          )
        )
        return render_bad_request(
          GENERIC_ERROR_MESSAGE,
          'card_last_4'
        )
      end

      if customer.person.ssn_last_4 != request[:ssn_last_4]
        credit_card_account.api.log_disqualified_activation_attempt(
          channel:       'public_site',
          error_message: 'Account cannot be activated'
        )
        Amount::Event::Alert.warn(
          SSNMismatchError.new(
            'Credit Card SSN Mismatch with Customer',
            customer_id:            customer.id,
            credit_card_account_id: credit_card_account.id
          )
        )
        return render_bad_request(
          GENERIC_ERROR_MESSAGE,
          'ssn_last_4'
        )
      end

      api_response = AccountManagement::Api::Consumer::CreditCardAccount::ActivateCard.call!(
        customer,
        account_uuid: credit_card_account.servicing_account.uuid,
        card_last_4:  params[:card_last_4],
        ssn_last_4:   params[:ssn_last_4],
        channel:      params[:channel],
      )

      render(
        status: api_response[:is_success] ? :ok : :internal_server_error,
        json:   api_response
      )
    end
    # rubocop:enable Metrics/MethodLength

    private

    def render_bad_request(error_message, field)
      render(
        status: :bad_request,
        json:   {
          is_success: false,
          error:      {
            type:    'request',
            field:   field,
            message: error_message,
          },
        }
      )
    end

    def customer_application
      @customer_application ||= open_application || new_application
    end

    def open_application
      current_or_guest_customer
        .customer_applications
        .where(status: :open, product_type: :credit_card)
        .find do |application|
          application_policy(application) == policy_identifier_from_params(params).to_s
        end
    end

    def policy_identifier_from_params(values)
      brand = values[:brand]
      return :credit_card unless brand

      policies = AccountOpening::Modules::ApplicationLifecycle::Interface.policies

      "#{brand.downcase}_credit_card"
        .to_sym
        .tap { |policy| raise InvalidPolicyError unless policies.key?(policy) }
    end

    def new_application
      policy_identifier = policy_identifier_from_params(params)
      response = ::AccountOpening::Api::System::Application::GenericCreateApplication.call!(
        customer_id:            current_or_guest_customer.id,
        policy_identifier:      policy_identifier,
        channel:                policy_identifier,
        marketing_source:       params[:landing_keyword]&.to_sym || :organic,
        custom_creation_fields: {},
        attribution_metadata:   {},
      )

      current_or_guest_customer.current_sign_in_ip = request.remote_ip
      current_or_guest_customer.save(validate: false)
      application = current_or_guest_customer.customer_applications.find_by(
        uuid: response.data[:application_uuid]
      )
      application.update_user_agent(request.env['HTTP_USER_AGENT'])
      application.short_form          = {}
      application.partial_application = {}

      application.last_seen_ip = request.remote_ip
      application.save

      # Updates Pricing and Rewards Strategy IDs
      attempt_to_add_pricing_strategy_and_rewards_from_params(application, params)

      save_visitor_event!(application, checkpoint: :enter_application, save_application: true)
      application
    end

    def application_policy(application)
      application.application_lifecycle_policies.newest&.policy_identifier
    end

    def sign_out_customer
      # this sign_out method comes from Devise::Controllers::SignInOut#sign_out
      #
      # The call to #sign_out MUST be unscoped (i.e., no arguments). Calling the
      # method with arguments will leave :guest_customer_id in the session.

      # sign_out mutates the customer record. Need explicit lock on current_customer
      # to avoid stale object error
      if current_customer
        current_customer.with_lock { sign_out }
      else
        sign_out
      end
    end
  end
end
