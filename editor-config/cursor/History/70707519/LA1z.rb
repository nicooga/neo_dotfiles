require "virtual_column"
require "avant/credit_card_api"
require "avant/product_status_change/reasons/mixins/product"
require "avant/soft_delete_helper"
require "optimizely/feature_flags"
require "avant/hardship_service_api"
require 'avant/ciam/data_updater'

# CreditCard is the Avant branded Credit Card Product.
# @note this IS related to CreditCardAttempt
class CreditCardAccount < ApplicationRecord
  include UUIDHelper
  include Avant::SoftDeleteHelper
  include VirtualColumn::Store
  include Product::CommonWorkflow
  include CreditCardAccount::WorkflowTransitions
  include CreditCardAccount::AutopayStrategy
  include CreditCardAccount::CardmemberAgreementFees
  include CreditCardAccount::CardmemberAgreementInputs
  extend Optimizely::FeatureFlags
  include Product::WorkflowTransitions
  include Product::Verification
  include Product::Introspection
  include Product::CommonScopes
  include Product::Emails
  include ::Avant::ProductStatusChange::Reasons::Mixins::Product
  include Product::Configuration
  include Product::ChargeOff
  include Product::Collateral
  include Product::ServicingAccount
  include Product::MarketPlace
  include Product::ServicingInterface
  include Product::Cancellation
  include CreditCardAccount::Scenarios

  class LatestBankruptcySelectionError < StandardError; end

  class UnexpectedScenarioError < Amount::Event::ErrorWithContext; end

  RECENT_REJECTION_PERIOD_DAYS = 7
  APPROVED_STALENESS_CUTOFF_DAYS = 14
  VALID_ACTIVATION_CODES = %w[7 8]
  SETTLEMENT_COMPLETED = "settlement_completed"
  IN_SETTLEMENT = "in_settlement"
  NOT_IN_SETTLEMENT = "not_in_settlement"
  SETTLEMENT_ELIGIBLE_BANKRUPTCY_STATUSES = %w[claimed withdrawn dismissed].freeze
  STATUS_SCHEDULED = "scheduled"
  STATUS_FDR_PREPARED = "fdr_prepared"
  STATUS_FDR_SENT = "fdr_sent"
  STATUS_TREASURY_PREPARED = "treasury_prepared"
  STATUS_TREASURY_PROCESSED = "treasury_processed"
  STATUS_RETURN_FDR_PREPARED = "return_fdr_prepared"
  STATUS_RETURN_FDR_SENT = "return_fdr_sent"
  PAYMENT_PLAN_ACTIVE_STATUS = "active"
  PAYMENT_PLAN_LOCKED_IN_STATUS = "locked_in"
  PAYMENT_PLAN_LIVE_STATUS = [PAYMENT_PLAN_ACTIVE_STATUS, PAYMENT_PLAN_LOCKED_IN_STATUS].freeze
  PAYMENT_PLAN_MODIFICATION_STRUCTURE = "modification"
  PAYMENT_PLAN_SHORT_TERM_STRUCTURE = "short_term"
  PAYMENT_PLAN_INVALID_SETTLEMENT_STRUCTURES = [PAYMENT_PLAN_MODIFICATION_STRUCTURE, PAYMENT_PLAN_SHORT_TERM_STRUCTURE]
  PAYMENT_COMPLETED_STATUSES = [
    STATUS_FDR_PREPARED, STATUS_FDR_SENT, STATUS_TREASURY_PREPARED, STATUS_TREASURY_PROCESSED
  ].freeze
  MAXIMUM_SCHEDULED_PAYMENT_COUNT = 2
  MINIMUM_BALANCE_TO_IVR_PAYMENT_CENTS = 100
  BOOL_REGEX = /(true|1|yes)/i.freeze
  FISERV_PROMOTION_DYL = "DL"

  has_paper_trail
  has_versions

  delegate :policy, :config, :state, to: :customer_application

  belongs_to :customer_application, foreign_key: :customer_application_uuid, primary_key: :uuid, inverse_of: :credit_card_accounts
  belongs_to :customer, foreign_key: :customer_uuid, inverse_of: :credit_card_accounts, primary_key: :uuid

  has_one :collection_case, as: :product
  has_one :collection_agency, through: :collection_case

  has_many :underwriting_decisions, as: :product, primary_key: :uuid, foreign_key: :product_uuid, inverse_of: :product
  has_many :verification_tasks, as: :product, primary_key: :uuid, foreign_key: :product_uuid, inverse_of: :product
  has_many :verification_warnings, as: :product, primary_key: :uuid, foreign_key: :product_uuid # warnings were fact-system based and removed as of May 2020 #VERWARNINGCLEANUPTAG
  has_many :notes, as: :notable
  has_many :processing_event_blockers, as: :blockable, foreign_key: :blockable_uuid, primary_key: :uuid
  has_many :card_onboarding_calls, foreign_key: :credit_card_account_uuid, primary_key: :uuid
  has_many :delinquency_reasons, as: :product, primary_key: :uuid, foreign_key: :product_uuid, inverse_of: :product
  has_many :collection_work_logs, as: :collectable

  has_many :collateral_owners, as: :collateral_ownable, foreign_key: :collateral_ownable_uuid, primary_key: :uuid
  has_many :product_contract_verifications, as: :product, foreign_key: :product_uuid, primary_key: :uuid
  has_many :collateral_verifications, as: :verifiable_product, foreign_key: :verifiable_product_uuid, primary_key: :uuid
  has_many :verification_agents, through: :collateral_verifications
  has_many :financial_ownerships, as: :product, foreign_key: :product_uuid, primary_key: :uuid
  has_many :requested_refunds, as: :product, foreign_key: :product_uuid, primary_key: :uuid
  has_many :cardmember_agreement_logs, inverse_of: :credit_card_account, foreign_key: :credit_card_account_id, primary_key: :id

  has_many :product_sales, as: :product, foreign_key: :product_uuid, primary_key: :uuid
  has_many :debt_sales, through: :product_sales

  has_many :credit_card_account_status_logs, -> { order("created_at asc") } do
    def most_recent_timestamp_for_status(status)
      # The relation is already sorted
      if most_recent_timestamp = with_status(status).last
        most_recent_timestamp.created_at
      end
    end
  end

  monetize :annual_membership_fee_amount_cents, allow_nil: true
  monetize :credit_line_amount_cents, allow_nil: true

  scope :approved_or_funded, -> { where(status: ["approved", *funded_statuses]) }

  scope :with_account_history, -> { where(status: [:rejected, :approved, :charged_off, :issued]) }
  scope :issued, -> { where(status: "issued") }
  scope :rejected, -> { where(status: "rejected") }
  scope :closed, -> { where(status: "closed") }
  scope :not_cancelled_or_rejected, -> { where.not(status: ["cancelled", "rejected"]) }
  scope :post_issuance, -> { where(status: post_issuance_statuses) } # from WorkflowTransitions
  scope :end_of_the_road, -> { where(status: end_of_the_road_statuses).where("#{table_name}.customer_uuid is not ?", nil) }
  scope :not_ck_easy_apply_source, -> { joins(:customer_application).where.not(customer_applications: {source: "creditkarma_easyapply_card"}) }

  # Copied from loan_and_credit_line_scopes.rb, should make that generic to all products in the future
  scope :has_verification_tasks, -> {
                                   joins("join verification_tasks on verification_tasks.product_type = '#{self}'
    AND verification_tasks.product_uuid = #{table_name}.uuid").where("verification_tasks.name = '#{Avant::Verification::Task::Start::NAME}'")
                                 }

  scope :verification_started, ->(time_frame) {
                                 joins("join verification_tasks on verification_tasks.product_type = '#{self}'
        AND verification_tasks.product_uuid = #{table_name}.uuid").where("verification_tasks.name = '#{Avant::Verification::Task::Start::NAME}' AND verification_tasks.created_at >= ?", time_frame)
                               }

  attr_accessor :whodunnit

  validate :no_current_inflight_products

  before_save :record_status_change

  after_commit_with_previous_changes :ciam_data_updater

  virtual_attribute :cached_account, using: :redis, expiration: 1.days.to_i

  # @!group Optimizely Feature Flags

  # @!parse
  #   include Optimizely::FeatureFlags::Helpers

  # @!macro made_by_optimizely_feature
  #
  #   @note This method was generated by {Optimizely::FeatureFlags#optimizely_feature}. See
  #     its source for the implementation of this method
  #   @see Optimizely::FeatureFlags#optimizely_feature
  #   @see Optimizely::FeatureFlags::Helpers helper methods used for context

  # @!macro optimizely_feature
  #   @!method $1_enabled?
  #     Determines if the `$1` feature is enabled for this record
  #     @!macro made_by_optimizely_feature
  #     @see #$1_disabled?
  #     @return [Boolean]
  #
  #   @!method $1_disabled?
  #     Determines if the `$1` feature is disabled for this record
  #     @!macro made_by_optimizely_feature
  #     @see #$1_enabled?
  #     @return [Boolean]
  #
  #   @!method $1_decision
  #     Runs an Optimizely decision for the `$1` feature on this record.
  #
  #     Decisions include whether or not that feature is enabled for the record, but also include
  #     variables that you have hooked up to the feature in Optimizely.
  #
  #     @!macro made_by_optimizely_feature
  #     @see Optimizely::Gateway.optimizely_decision
  #     @return [Optimizely::Decide::OptimizelyDecision]
  optimizely_feature :short_term_payment_plan

  optimizely_feature :credit_card_settlements

  optimizely_feature :settlement_payment_updates

  # @!macro optimizely_feature
  optimizely_feature :card_account_summary_caching

  # @!macro optimizely_feature
  optimizely_feature :card_rpf_fees,
    additional_context: :current_cardholder_pricing_strategy_identifier

  # @!macro optimizely_feature
  optimizely_feature :revoke_card_workflow

  # @!macro optimizely_feature
  optimizely_feature :card_change_in_terms_opt_out

  # @!macro optimizely_feature
  optimizely_feature :fsr_on_closed_accounts

  # @!macro optimizely_feature
  optimizely_feature :cardmember_agreement_workflow_delay,
    additional_context: [:current_cardholder_pricing_strategy_identifier, :formatted_upc_10_code]

  # @!macro optimizely_feature
  optimizely_feature :resend_email_verification

  # @!macro optimizely_feature
  optimizely_feature :card_payment_plan_autopay

  # @!macro optimizely_feature
  optimizely_feature :override_giact_ca01

  # @!macro optimizely_feature
  optimizely_feature :promotion_dyl

  # @!endgroup

  FINAL_CLOSED_STATES = [
    Avant::CreditCardApi::Base::CREDIT_CARD_STATUS_CHARGED_OFF,
    Avant::CreditCardApi::Base::CREDIT_CARD_STATUS_REVOKED_WITHOUT_BALANCE,
    Avant::CreditCardApi::Base::CREDIT_CARD_STATUS_CLOSED_WITHOUT_BALANCE
  ].freeze

  CLOSED_STATES = [
    Avant::CreditCardApi::Base::CREDIT_CARD_STATUS_CLOSED_WITH_BALANCE,
    Avant::CreditCardApi::Base::CREDIT_CARD_STATUS_REVOKED_WITH_BALANCE
  ].concat(FINAL_CLOSED_STATES).freeze

  ACCOUNT_STATUS_CLOSED = "closed".freeze

  PRE_ISSUANCE_STATUSES = %w[applied approved cancelled rejected].freeze

  def self.customer_has_issued_no_fraud_credit_card_account?(customer)
    customer.credit_card_accounts.issued.exists? { |cc| cc.active_no_fraud? }
  end

  def self.customer_has_active_or_recently_rejected_or_sold_account?(customer)
    has_active_account?(customer) || has_recently_rejected_account?(customer) || has_sold_account?(customer)
  end

  def self.has_active_account?(parent)
    # parent object could be customer or customer_application
    parent.credit_card_accounts.approved_or_issued.exists?
  end

  def self.has_recently_rejected_account?(parent)
    # parent object could be customer or customer_application
    last_rejected_at = parent.credit_card_accounts.rejected.map(&:rejected_at).compact.map(&:to_date).max
    !!(last_rejected_at && last_rejected_at >= RECENT_REJECTION_PERIOD_DAYS.days.ago.to_date)
  end

  def self.has_sold_account?(parent)
    # parent object could be customer or customer_application
    parent.credit_card_accounts.any?(&:sold?)
  end

  def activatable?
    account[:credit_cards]&.any? { |card| VALID_ACTIVATION_CODES.include?(card[:activation_code]) }
  end

  ##### STALENESS LOGIC #####
  def self.stale_uuids
    [
      stale_cards_in_ver,
      stale_cards_not_in_ver,
      stale_approvals
    ].reduce([]) { |mem, relation| mem + relation.pluck(:uuid) }
  end

  def self.stale_cards_in_ver
    in_ver_before_cutoff(AppConfig.verification.card_in_ver_staleness_cutoff_days.days.ago, :applied)
  end

  def self.stale_cards_not_in_ver
    not_in_ver.created_before_cutoff(AppConfig.verification.card_not_in_ver_staleness_cutoff_days.days.ago)
  end

  def self.stale_approvals
    approved.in_ver_before_cutoff(APPROVED_STALENESS_CUTOFF_DAYS.days.ago, :approved)
  end

  def self.in_ver_before_cutoff(cutoff, status)
    raise ArgumentError unless %i[applied approved].include?(status)

    ver_relation = VerificationTask.exists_for(self)
      .group("verification_tasks.product_uuid")
      .having("MIN(verification_tasks.created_at) < ?", cutoff)

    send(status).where("EXISTS (#{ver_relation.to_sql})")
  end

  def self.created_before_cutoff(cutoff)
    before(cutoff, by: :created_at)
  end

  def self.not_in_ver
    applied_or_approved
      .where("NOT EXISTS (#{VerificationTask.exists_for(self).to_sql})")
  end

  ##### END STALENESS LOGIC #####

  def ciam_data_updater
    if (previous_changes.blank? || %w(status).any? { |x| attribute_previously_changed?(x) })
      Avant::Ciam::DataUpdater.spawn_job_for_mutation_if_needed(self.customer)
    end
    true
  end

  def supports_cycles?
    true
  end

  def avantcredit_owned?
    false
  end

  def webbank_owned?
    true
  end

  def should_be_webbank_owned?
    true
  end

  def regions_owned?
    false
  end

  def product_type
    :credit_card
  end

  def product_subtype
    nil
  end

  def owner
    nil
  end

  def payment_method
    nil
  end

  def funding_method
    nil
  end

  def funding_date
    nil
  end

  def ach_opted_out
    !api.autopay_plan
  end

  ##
  # Have API as a method, so we can actually
  # get info on a Credit Card
  def api
    Avant::CreditCardApi::Factory.create(self)
  end

  ##
  # HardshipService Payment Protection API interface
  def payment_protection_api
    @payment_protection_api ||= Avant::HardshipServiceApi::Factory.payment_protection(self)
  end

  def currently_enrolled_in_payment_protection?
    payment_protection_api.currently_active_status?
  end

  def customer_id
    customer.id
  end

  def needs_to_sign_contracts?
    false
  end

  def signed_all_contracts?(has_to_match_product: nil)
    true
  end

  def has_never_signed_contracts?
    false
  end

  def charged_off?
    product_status == Avant::CreditCardApi::Base::CREDIT_CARD_STATUS_CHARGED_OFF
  end

  def has_bankrupt_status_per_credit_card_api?
    external_status == Avant::CreditCardApi::Base::EXTERNAL_BANKRUPT_STATUS_CODE
  end

  def latest_bankruptcy_is_settlement_eligible?
    bk = latest_bankruptcy
    return false if bk.nil?

    SETTLEMENT_ELIGIBLE_BANKRUPTCY_STATUSES.include?(bk.status.to_s.downcase)
  rescue LatestBankruptcySelectionError => e
    Amount::Event::Alert.info("[BK_ELIGIBILITY_UNEXPECTED] #{e.class}: #{e.message}")
    false
  rescue => e
    Amount::Event::Alert.info("[BK_ELIGIBILITY_UNEXPECTED] #{e.class}: #{e.message}")
    false
  end

  def has_no_bankruptcies?
    customer&.bankruptcies.blank?
  end

  def latest_bankruptcy
    bks = customer&.bankruptcies
    return nil if bks.blank?

    invalid = bks.select { |b| b.eff_date.nil? || b.updated_at.nil? || b.id.nil? }
    if invalid.any?
      details = invalid.map do |b|
        missing = []
        missing << "eff_date" if b.eff_date.nil?
        missing << "updated_at" if b.updated_at.nil?
        missing << "id" if b.id.nil?
        "#{b.respond_to?(:uuid) ? b.uuid : b.object_id}: missing #{missing.join(", ")}"
      end.join(" | ")
      raise LatestBankruptcySelectionError,
        "Could not fetch latest bankruptcy for customer #{customer&.uuid} " \
        "because one or more records are missing fields (#{details})"
    end

    bks.max_by { |b| [b.eff_date, b.updated_at, b.id] }
  end

  def has_charged_off_status_per_credit_card_api?
    external_status == Avant::CreditCardApi::Base::CHARGED_OFF_STATUS_CODE
  end

  def has_revoked_status_per_credit_card_api?
    external_status == Avant::CreditCardApi::Base::EXTERNAL_REVOKED_STATUS_CODE
  end

  def has_lost_status_per_credit_card_api?
    external_status == Avant::CreditCardApi::Base::LOST_STATUS_CODE
  end

  def has_closed_status_per_credit_card_api?
    external_status == Avant::CreditCardApi::Base::EXTERNAL_CLOSED_STATUS_CODE
  end

  def has_stolen_status_per_credit_card_api?
    external_status == Avant::CreditCardApi::Base::STOLEN_CARD_STATUS_CODE
  end

  def has_active_modification_or_short_term_payment_plan?
    api.payment_plans.any? do |payment_plan|
      payment_plan = payment_plan.with_indifferent_access
      PAYMENT_PLAN_LIVE_STATUS.include?(payment_plan["internal_status"]) &&
        PAYMENT_PLAN_INVALID_SETTLEMENT_STRUCTURES.include?(payment_plan["structure"])
    end
  end

  def has_fraud_status_per_credit_card_api?
    external_status == Avant::CreditCardApi::Base::STOLEN_CARD_STATUS_CODE ||
      (external_status == Avant::CreditCardApi::Base::CHARGED_OFF_STATUS_CODE &&
        external_status_reason_code == Avant::CreditCardApi::Base::FRAUD_STATUS_CODE)
  end

  def has_deceased_status_reason_per_credit_card_api?
    external_status_reason_code == Avant::CreditCardApi::Base::DECEASED_STATUS_REASON_CODE
  end

  def revoked_with_balance?
    product_status == Avant::CreditCardApi::Base::CREDIT_CARD_STATUS_REVOKED_WITH_BALANCE
  end

  def revoked_without_balance?
    product_status == Avant::CreditCardApi::Base::CREDIT_CARD_STATUS_REVOKED_WITHOUT_BALANCE
  end

  def closed_with_balance?
    product_status == Avant::CreditCardApi::Base::CREDIT_CARD_STATUS_CLOSED_WITH_BALANCE
  end

  def closed_without_balance?
    product_status == Avant::CreditCardApi::Base::CREDIT_CARD_STATUS_CLOSED_WITHOUT_BALANCE
  end

  def has_debt_management_company?
    client_classification_1_code == Avant::CreditCardApi::Base::UPC_DMC_CODE
  end

  def closed?
    status == ACCOUNT_STATUS_CLOSED
  end

  def has_scheduled_ach_payment?
    api.payments&.any? do |payment|
      payment["internal_status"] == "scheduled" && payment["payment_method"] == Payments::BasePayment.ach
    end
  end

  def make_onboarding_call(options = {})
    CardOnboardingCall.send_for(customer_application, options)
  end

  def closed_date
    Date.strptime(account[:closed_date], "%Y-%m-%d")
  rescue
    nil
  end

  def product_status
    account[:product_status]
  end

  def external_status
    account[:external_status]
  end

  def cycles_delinquent
    account[:cycles_delinquent]
  end

  def cycle_day_of_month
    account[:billing_cycle_code]
  end

  def external_status_reason_code
    account[:external_status_reason_code]
  end

  def client_classification_1_code
    account[:client_classification_1_code]
  end

  def client_classification_2_code
    account[:client_classification_2_code]
  end

  # Gets the value of UPC5 (from Fiserv)
  #
  # This will likely either be `" "` or `"Y"`
  #
  # @return [String] the value of the UPC5 for the account
  def client_classification_5_code
    account[:client_classification_5_code]
  end

  def current_cardholder_pricing_strategy_identifier
    account[:current_cardholder_pricing_strategy_identifier]
  end

  def metro_comment_code
    account[:metro_comment_code]
  end

  def metro_account_status_code
    account[:metro_account_status_code]
  end

  def account
    return final_account.with_indifferent_access if final_account.present?

    api_account = getset_cached_account.with_indifferent_access
    new_product_status = api_account[:product_status]

    check_and_update_status(new_product_status)
    check_and_save_final_account(new_product_status)
    api_account
  end

  def check_and_update_status(new_product_status)
    return unless CLOSED_STATES.include?(new_product_status)
    update_attribute(:status, "closed")
    save!
  end

  def check_and_save_final_account(new_product_status)
    return unless FINAL_CLOSED_STATES.include?(new_product_status)
    acct = getset_cached_account.with_indifferent_access
    acct[:closed_date] = Date.current.to_s unless acct[:closed_date]
    self.final_account = acct
    save!
  end

  def getset_cached_account
    if Avant::Env.credit_card_account_cache_disabled?
      api.account.to_hash
    elsif (cache = cached_account) # assignment intentional
      cache
    else
      self.cached_account = api.account.to_hash
    end
  end

  # Update external status for added DMC (dead management company), so
  # we can track if the account is closed due to DMC
  def update_external_status_for_added_dmc
    api.update_external_status_for_added_dmc
  end

  def invalidate_final_account!
    self.final_account = nil
    invalidate_cached_account!
    save!
  end

  def invalidate_cached_account!
    cached_account_clear
  end

  def late?
    !!(product_status == Avant::CreditCardApi::Base::CREDIT_CARD_STATUS_LATE)
  end
  alias_method :delinquent?, :late?

  def active?
    self.class.active_statuses.include? status.to_sym
  end

  def active_no_fraud?
    account = api.account
    external_status_code = account.external_status
    fraud_reason_status_code = account.external_status_reason_code

    account.status == Avant::CreditCardApi::Base::EXTERNAL_ACTIVE_STATUS &&
      external_status_code&.to_s != Avant::CreditCardApi::Base::STOLEN_CARD_STATUS_CODE &&
      !(external_status_code&.to_s == Avant::CreditCardApi::Base::CHARGED_OFF_STATUS_CODE &&
        fraud_reason_status_code&.to_s == Avant::CreditCardApi::Base::FRAUD_STATUS_CODE)
  end

  def open_date
    account[:open_date]
  end

  def record_status_change
    if status_changed?
      csl = credit_card_account_status_logs.build
      csl.status = status

      csl.credit_decision = decisioning_interface.credit_decision

      csl.reason = status_change_reason
      csl.whodunnit = whodunnit

      # should not explicitly save the csl, it is an association

      # reset the status_change_reason so another status change
      # in the same request doesn't pick it up
      self.status_change_reason = nil
    end
  end

  def no_current_inflight_products
    if customer && applied?
      # if you remove the new_record? check you need to check where id != self.id in query
      # updated here to block if any applied product exists
      if new_record? && customer.has_any_inflight_products?
        error = UnexpectedScenarioError.new("Another Inflight Product Already Exists",
          customer_id: customer_id, customer_application_id: customer_application.try(:id))
        Amount::Event::Alert.debug_exception(error)
        errors.add(:existing_inflight_product, "An inflight product already exists")
      end
    end
  end

  def current_financial_ownership
    return @current_financial_ownership if defined?(@current_financial_ownership)
    @current_financial_ownership = financial_ownerships.current
  end

  def sold?
    client_classification_1_code == Avant::CreditCardApi::Base::UPC1_SOLD_OFF_CODE
  end

  def decisioning_interface
    customer_application.try(:decisioning_interface)
  end

  def white_label?
    false
  end

  def post_issuance?
    !PRE_ISSUANCE_STATUSES.include?(status)
  end

  def onboarding_request_has_been_processed_by_fdr?
    !!account["current_credit_line_change_date"]
  end

  def pending_refund_requests
    requested_refunds.pending.chronologic
  end

  def enrolled_in_autopay?
    !!account[:autopay_active]
  end

  # Ensures that the CreditCardAccount aprs match the product decision
  # Sometimes these aprs get out of sync
  def ensure_correct_rates_terms!
    apr = customer_application.decisioning_interface.apr
    self.apr_percentage = apr if apr

    cash_apr = customer_application.decisioning_interface.cash_advance_apr
    self.cash_apr_percentage = cash_apr if cash_apr
  ensure
    save_and_rescue_stale_object
  end

  def save_and_rescue_stale_object
    Util::Flow.with_retry_and_reload self do
      save if changed?
    end
  end

  def issued_or_closed?
    ["issued", "closed"].include?(status)
  end

  def delinquent_internal_status?
    [
      Avant::CreditCardApi::Base::INTERNAL_DELINQUENT_STATUS_CODE,
      Avant::CreditCardApi::Base::INTERNAL_OVERLIMIT_DELINQUENT_STATUS_CODE
    ].include?(account["account_internal_status"])
  end

  def inactive_status_for_open_cards?
    has_bankrupt_status_per_credit_card_api? ||
      has_charged_off_status_per_credit_card_api? ||
      has_revoked_status_per_credit_card_api? ||
      has_fraud_status_per_credit_card_api?
  end

  def inactive_status_per_credit_card_api?
    inactive_status_for_open_cards? ||
      has_closed_status_per_credit_card_api?
  end

  def timestamps_for_status(status, status_logs)
    status_logs.filter { |status_log| status_log.status == status }.map(&:created_at)
  end

  def timestamps_for_final_decision_status(status, status_logs)
    return [] unless status_is_most_recent?(status, status_logs)
    timestamps_for_status(status, status_logs)
  end

  def status_is_most_recent?(status, status_logs)
    status == status_logs&.last&.status
  end

  # Returns the settlement status for the account according to redis cache data updated periodically by DSP
  def settlement_status
    return NOT_IN_SETTLEMENT unless first_data_account_reference
    settlement = settlement_data
    if !settlement["in_settlement"] && !settlement["is_completed"]
      NOT_IN_SETTLEMENT
    elsif settlement["in_settlement"]
      IN_SETTLEMENT
    else
      SETTLEMENT_COMPLETED
    end
  end

  def in_settlement?
    settlement_status != NOT_IN_SETTLEMENT
  end

  def settlement_data
    key = "settlement_redis_key:#{first_data_account_reference}"
    if REDIS.exists(key)
      transform_cache_values(REDIS.hgetall(key))
    else
      {"in_settlement" => false}
    end
  end

  def eligible_for_ivr_payment?
    customer.active_payment_accounts.any? &&
      ivr_payment_values[:valid_scheduled_amount] &&
      ivr_payment_values[:valid_scheduled_count]
  end

  def ivr_payment_amount_limits
    return [0, 0] unless eligible_for_ivr_payment?
    return [0, 0] if ivr_payment_values[:max_allowed] < 1
    [1, ivr_payment_values[:max_allowed]]
  end

  # Checks if there is an older inactive account for the same customer.
  #
  # Returns:
  # - false if there is no final account present.
  # - @older_inactive_account if it has already been defined.
  # - true if there is an older inactive account for the same customer.
  def older_inactive_account?
    return false unless final_account.present?

    return @older_inactive_account if defined? @older_inactive_account

    @older_inactive_account = CreditCardAccount.not_cancelled_or_rejected
      .where(customer_uuid: customer_uuid)
      .where("created_at > ?", created_at)
      .exists?
  end

  # Gets the variables for the card change in terms opt out decision
  #
  # @return [Hash] a hash with two keys:
  #   1. `:workflow_opt_out_date` - `String`: The start date of the change in terms opt out availability
  #   2. `:opt_out_term_length` - `Integer`: The number of days the customer has to opt out of the card change in terms
  def cit_opt_out_variables
    @card_change_in_terms_opt_out_variables ||= card_change_in_terms_opt_out_decision.variables.symbolize_keys
  end

  # Gets the card change in terms opt out start date string and parses it into a date
  #
  # @return [Date]
  def card_change_in_terms_opt_out_start_date
    Date.parse(cit_opt_out_variables[:workflow_opt_out_date])
  end

  # Gets the card change in terms opt out end date calculated by adding term length to start date
  #
  # @return [Date]
  def card_change_in_terms_opt_out_end_date
    card_change_in_terms_opt_out_start_date + cit_opt_out_variables[:opt_out_term_length].days
  end

  # Checks if the account is eligible for the card change in terms opt out decision
  # start and end date inclusive
  #
  # @return [Boolean]
  def eligible_for_card_change_in_terms_opt_out?
    return false unless card_change_in_terms_opt_out_enabled?

    Date.current.between?(card_change_in_terms_opt_out_start_date, card_change_in_terms_opt_out_end_date)
  end

  # Gets largest amount a return-payment (NSF) fees can be for the account
  #
  # @return [Integer] the maximum returned-payment fee the customer can receive, in cents
  def rpf_maximum_fee_amount_cents
    @rpf_maximum_fee_amount_cents ||= AppConfig.credit_card_limits.returned_payment_fee.int.to_money.cents
  end

  # Gets whether the account can receive return-payment (NSF) fees
  #
  # @return [Boolean]
  def rpf_fee_eligible?
    !!rpf_configuration[:can_assess_rpf_fees]
  end

  # Gets the config variables for return-payment (NSF) fees for the account
  #
  # @return [Hash] a hash with three keys:
  #   1. `:can_assess_rpf_fees` - `Boolean`: Whether or not the account is eligible for RPF fees
  #   2. `:initial_fee_amount_cents` - `Integer`: The fee the account will receive for the first returns
  #   3. `:sequential_fee_amount_cents` - `Integer`: The fee the account will receive for additional returns
  def rpf_configuration
    @rpf_configuration ||= card_rpf_fees_decision.variables.symbolize_keys
  end

  # Determines the minimum APR (Annual Percentage Rate)
  #
  # It compares between the maximum merchandise APR and the purchase APR of an account.
  #
  # It's used in for CMAs, payment plans terms, and other customer-facing scripting.
  #
  # @return [Float] The minimum APR value between the maximum merchandise APR and the purchase APR.
  # @return [nil] if the account has not finalized in Fiserv yet (it was onboarded today)
  def merchandise_apr
    [account[:maximum_merchandise_apr], account[:purchase_apr]].compact.min
  end

  def first_data_account_reference
    @first_data_account_reference ||= account[:first_data_account_reference]
  end

  # Returns payment protection status via Hardship Service.
  #
  # Utilized by GraphQL endpoint `paymentProtectionStatus` and as part of Rails-based Payment Protection SSO to Aon.
  #
  # @return [Boolean] true if the account is enrolled in Payment Protection and is active.
  # @return [Boolean] false if the account has been enrolled in Payment Protection but is not currently active.
  # @return [nil] If the account has never been enrolled or if there's an error looking up data.
  def payment_protection_status
    begin
      enrollment = payment_protection_api.latest_enrollment
      if enrollment
        payment_protection_api.currently_active_status?
      else
        nil
      end
    rescue => e
      Amount::Event::Alert.info("Failed to fetch payment protection status for credit card account #{uuid}: #{e.message}")
      nil
    end
  end

  # Returns payment protection SSO path.
  #
  # As part of the process, this generates JWT-encoded data containing attributes necessary for
  # the SSO/SAML integration (fiserv_account_id).
  #
  # @return [String] URL path to initiate SSO to Payment Protection.
  # @return [nil] If there's an error looking up data.
  def payment_protection_sso_path
    begin
      return nil if payment_protection_status.nil?

      # Send fiserv account ID, JWT encoded.
      jwt_data = Avant::Api::Authentication::Jwt.encode_miscellaneous_data(data: {
        fiserv_account_id: self.first_data_account_reference
      })

      "sso/payment_protection?jwtData=#{jwt_data}"
    rescue => e
      Amount::Event::Alert.info("Failed to generate Payment Protection SSO path for credit card account #{self.uuid}: #{e.message}")
      nil
    end
  end

  private

  def transform_cache_values(cache)
    {
      "first_data_account_reference" => cache["first_data_account_reference"],
      "in_settlement" => !!(cache["in_settlement"] =~ BOOL_REGEX),
      "is_completed" => !!(cache["is_completed"] =~ BOOL_REGEX),
      "payment_method" => cache["payment_method"],
      "settlement_type" => cache["settlement_type"],
      "number_of_payments" => cache["number_of_payments"].to_i,
      "amount_due_monthly" => cache["amount_due_monthly"].to_i,
      "amount_due_remaining" => cache["amount_due_remaining"].to_i,
      "amount_due_in_full" => cache["amount_due_in_full"].to_i,
      "start_date" => cache["start_date"],
      "date_monthly_due" => cache["date_monthly_due"],
      "date_in_full_due" => cache["date_in_full_due"]
    }
  end

  def customer_has_valid_bank_account?
    !customer.customer_has_bad_bank_account?
  end

  def ivr_payment_values
    @ivr_payment_values ||= calculate_ivr_payment_values
  end

  # Calculates the values needed to determine if a customer is eligible for IVR payments
  def calculate_ivr_payment_values
    result = {
      scheduled_payments_sum: 0,
      pending_payments_sum: 0,
      return_payments_sum: 0,
      scheduled_payments_count: 0,
      valid_scheduled_amount: false,
      valid_scheduled_count: false,
      max_allowed: 0
    }

    api.payments.each do |p|
      amount = p["amount_cents"]

      case p["internal_status"]
      when STATUS_SCHEDULED
        result[:scheduled_payments_sum] += amount
        result[:scheduled_payments_count] += 1 if p["origin"] != "autopay"
      when *PAYMENT_COMPLETED_STATUSES
        result[:pending_payments_sum] += amount
      when STATUS_RETURN_FDR_PREPARED, STATUS_RETURN_FDR_SENT
        result[:return_payments_sum] += amount
      else next
      end
    end

    credit_limit = account["credit_limit_cents"]
    current_balance = account["current_balance_cents"]
    result[:max_allowed] = current_balance - result[:pending_payments_sum] + result[:return_payments_sum] + (0.25 * credit_limit)

    result[:valid_scheduled_amount] = current_balance >= MINIMUM_BALANCE_TO_IVR_PAYMENT_CENTS &&
      result[:scheduled_payments_sum] <= result[:max_allowed]
    result[:valid_scheduled_count] = result[:scheduled_payments_count] < MAXIMUM_SCHEDULED_PAYMENT_COUNT

    result
  end
end
