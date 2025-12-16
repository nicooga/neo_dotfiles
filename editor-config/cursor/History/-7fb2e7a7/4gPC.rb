require 'avant/fraud_decisioning'
require 'avant/decisioning'
require 'avant/decisioning/policies/selector'
require 'policies/stats/customer_application'
require 'avant/verification_api/interface/standard'
require 'avant/verification_api/interface/g2_transition'
require 'avant/apply_logic/schema'
require './platforms/account_opening/modules/application_lifecycle/interface'

class CustomerApplication < ApplicationRecord
  module Decisioning
    CASHFLOW_UNDERWRITING_REPORTS = [:plaidypus_cra_base, :plaidypus_cra_income_insights]

    extend ActiveSupport::Concern

    included do
      delegate :live_model_score_mappings, :dark_model_score_mappings, to: :decisioning_interface
    end

    def decisioning_interface
      policy.interface_for(self)
    end

    def originations_interface
      @originations_interface ||= policy.originations_interface_for(self)
    end
    alias_method :o_api, :originations_interface

    def verifications_interface
      if policy.on_g2?
        Avant::VerificationApi::Interface::G2Transition.new(self, policy)
      else
        Avant::VerificationApi::Interface::Standard.new(self, policy)
      end
    end
    alias_method :ver_api, :verifications_interface

    def point_of_sale_interface
      require 'avant/point_of_sale/interface'
      Avant::PointOfSale::Interface.new(application: self)
    end
    alias_method :pos_api, :point_of_sale_interface

    def policy_owner
      policy.owner
    end

    def policy
      if application_lifecycle_policies.present?
        return AccountOpening::Modules::ApplicationLifecycle::Interface.application_policy_class(self)
      end

      policy_from_assignment || policy_selector.policy
    end

    def policy_selector
      ::Avant::Decisioning::Policies::Selector.new(self, policy_stats)
    end

    # TODO: move the config stuff below into a separate mixin from decisioning.

    # Get the configuration reference associated with this application's Policy.
    # @return [Policies::RecursiveOpenStruct] the configuration object from the
    #                                         assigned application policy.
    def config
      @config ||= begin
        if application_lifecycle_policies.any?
          Policy.fetch_from_files(*policy.g1_policy_files)
        else
          assign_application_policy!
          Policy.fetch_from_files(*application_policy.policy_files)
        end
      end
    end

    def policy_stats
      ::Avant::Decisioning::Policies::Stats.new(self).generate
    end

    def policy_config_stats
      @policy_config_stats ||= ::Policies::Stats::CustomerApplication.call!(
        application: self
      )
    end

    def construct_read_only_partial_api(missing: nil)
      opts = { missing: missing, partial_hash: self.partial_application || {} }
      opts = partial_application_schema_options.merge(opts)
      Avant::ApplyLogic::Schema.setup(**opts)
    end

    def partial_application_schema_options
      (stage_engine.apply_config.dig('partial_application_schema') || {}).symbolize_keys
    end

    def partial_application_schema
      Avant::ApplyLogic::Schema.registry.lookup(**partial_application_schema_options)
    end

    # Runs an event.
    # An event is a uniquely identified list of actions under the 'events' key.
    # Each action runs in order. See ActionRunner#run for more details.
    #
    # NB: "customer_application" is included as a default input, with 'self' as
    #     the value, when you call this method.
    # NB: "interface" is included as a default input, with
    #     'self.decisioning_interface' as the value, when you call this method.
    #
    # @see ActionRunner#run
    # @param [Symbol|String] event - the identifier for the event to run.
    # @param [Hash] arguments - the inputs for the actions in the event.
    # @param [Hash] options - options for the ActionRunner.
    # @return [ActionRunner::Result]
    def run_event(event, arguments={}, options={})
      require 'avant/actions' # lazily require actions

      actions = config.events[event]
      arguments = arguments.merge(
        customer_application: self,
        customer:             self.customer,
        interface:            self.decisioning_interface,
      )
      ActionRunner.new(actions).run(arguments, options)
    end

    # Runs an event.
    # An event is a uniquely identified list of actions under the 'events' key.
    # Each action runs in order. See ActionRunner#run for more details.
    #
    # NB: "customer_application" is included as a default input, with 'self' as
    #     the value, when you call this method.
    # NB: "interface" is included as a default input, with
    #     'self.decisioning_interface' as the value, when you call this method.
    #
    # @see ActionRunner#run!
    # @param [Symbol|String] event - the identifier for the event to run.
    # @param [Hash] arguments - the inputs for the actions in the event.
    # @param [Hash] options - options for the ActionRunner.
    # @return [ActionRunner::Result]
    # @raise [ActionRunner::Exception] if any actions cause an error.
    def run_event!(event, arguments={}, options={})
      require 'avant/actions' # lazily require actions

      actions = config.events[event]
      arguments = arguments.merge(
        customer_application: self,
        customer:             self.customer,
        interface:            self.decisioning_interface,
      )
      ActionRunner.new(actions).run!(arguments, options)
    end

    def enqueue_enter_lp_job!(async: true)
      if self.customer.acquire_generic_lock('decisioning_service:enter_lp_job')
        decisioning_interface.run_enter_loan_processing_event!(async: async)
      end
    end

    def non_refinance_funded?
      has_been_funded? && !refinance?
    end

    def refinance_and_current_or_paid_off?
      refinance? && (loan.try(:current) || refinancing_product.try(:paid_off?))
    end

    def applying_loans_already_issued?
      to_check = self.loans.applied_or_approved
      return false if to_check.empty?
      to_check.each do |loan|
        return false if !loan.loan_tasks.issue_loan.created_or_completed.exists?
      end
      true
    end

    def current_eligibility_decision
      self.eligibility_decisions.newest
    end

    def current_credit_decision
      credit_decisions.newest
    end

    def current_product_decision
      current_credit_decision.try(:product_decision)
    end

    def current_affordability_decision
      self.affordability_decisions.newest
    end

    def current_fraud_decision
      self.fraud_decisions.newest
    end

    def current_underwriting_decision
      self.underwriting_decisions.newest
    end

    def current_collections_decision
      self.collections_decisions.newest
    end

    def current_bank_transactions_decision
      self.bank_transactions_decisions.newest
    end

    def current_aml_decision
      self.aml_decisions.newest
    end

    def decisioning_source
      if customer
        pre_import_lead_source = Lead.pre_import.where(customer_id: customer.id).newest.try(:source)
      else
        pre_import_lead_source = nil
      end

      pre_import_lead_source || current_source
    end

    def lookup_assignable_sub_policy(sub_policy_type:)
      return if policy_assigned?
      base_policy = policy
      if base_policy && base_policy.sub_policy_enabled?
        base_policy.sub_config[sub_policy_type]
      end
    end

    def make_decisioning_policy_assignment(policy_name, info)
      self.build_decisioning_policy_assignment.tap do |assignment|
        assignment.decisioning_policy = lookup_policy_record(policy_name)
        assignment.decisioning_policy_info = make_decisioning_policy_info(info)
      end
    end

    def assign_policy!(policy_name, info)
      raise "Error: Customer Application #{self.id} already has an assigned decisioning policy" if policy_assigned?
      make_decisioning_policy_assignment(policy_name, info).save!
    end

    def assigned_decisioning_policy
      decisioning_policy_assignment&.decisioning_policy
    end

    def decisioning_policy_info
      decisioning_policy_assignment&.decisioning_policy_info
    end

    def lookup_policy_record(policy_name)
      selected_policy = DecisioningPolicy.where(name: policy_name).last
      return selected_policy if selected_policy
      create_policy_versions
      selected_policy = DecisioningPolicy.where(name: policy_name).last
      return selected_policy if selected_policy
      raise "#{policy_name} could not be found"
    end

    def make_decisioning_policy_info(info)
      DecisioningPolicyInfo.new.tap do |dpi|
        dpi.reasoning = info[:reasoning]
        dpi.inputs    = info[:inputs]
      end
    end

    def policy_assigned?
      !!decisioning_policy_assignment
    end

    def policy_from_assignment
      return unless policy_assigned?
      assigned_decisioning_policy&.constantize
    end

    def current_decline_monetization_decision
      decline_monetization_decisions.newest
    end

    def has_cancelled_product?
      loans.cancelled.exists? || credit_card_accounts.cancelled.exists?
    end

    def has_system_cancelled_product?
      loans.cancelled.any?{|loan| loan.loan_status_logs.pluck(:reason_category).last.to_s == 'system'}  ||
          credit_card_accounts.cancelled.any?{|card| card.credit_card_account_status_logs.pluck(:reason_category).last.to_s == 'system'}
    end

    def active_transunion_credit_report(exists: false)
      upper_bound = 1.day.since(closed_at(fallback_to_created_at: false) || Time.current)

      relation = customer.transunion_credit_reports \
                         .except(:order) \
                         .with_credit_vision \
                         .not_stale(on: created_at) \
                         .where(:created_at).less_or_equal_to(upper_bound)

      exists ? relation.exists? : relation.newest
    end

    def need_transunion_credit_report?
      return false unless policy.data_sources.include?(:transunion_soft_credit_report_info)

      valid_report = o_api.data(:transunion_soft_credit_report_info)

      return true if valid_report.blank? || valid_report.technical_failure || valid_report.no_subject_found_message_present

      # NOTE: There's a bug in the way the customer application engine's stage calculator
      # runs. There's a timing issue with some of the calls so we add a check on when
      # the newest credit report was created
      valid_report.security_freeze && valid_report.transunion_created_date <= 1.minute.ago
    end

    def cashflow_reports_present?
      CASHFLOW_UNDERWRITING_REPORTS.all? do |report|
        policy&.report_manager_requests&.include?(report) && o_api.report_manager.has?(report)
      end
    end


    def run_experian_credit_report!(pull_type)
      gateway_options = {
        username:     Avant::Env::CreditReports::Experian.username,
        password_key: Avant::Env::CreditReports::Experian.password_secret_key,
        ecal_url:     Avant::Env::CreditReports::Experian.ecal_url,
      }

      ExperianCreditReport.fetch(self, gateway_options, pull_type)
    end

    def stale?
      return false unless created_at && policy

      created_at <= policy.application_staleness_window_days.ago
    end

    def verification_started?
      product = self.product_type_specific_products.newest
      !!product&.verification_started?
    end

    def regions_existing_relationship?
      return false unless wla = self.white_label_attempt
      return false unless lsi = wla.lender_supplied_information.try(:with_indifferent_access)

      !!(lsi[:existing_regions_customer_flag] || lsi[:private_wealth_customer_flag] ||
        lsi[:priority_banking_customer_flag] || lsi[:regions_employee_flag])
    end

    def assign_application_policy!
      return if self.application_policy

      policy_file = Policy.file_for(policy_config_stats)
      # this will auto-save as it's triggered before create.
      self.build_application_policy(policy: policy_file)
    end

    private

    def create_policy_versions
      policy_list = config.decisioning_policy.policy_versions.constantize
      policy_list.each do |klass|
        DecisioningPolicy.where(name: klass.policy_name, class_name: klass.to_s, policy_type: klass.policy_type).first_or_create!
      end
    end
  end
end
