require_dependency 'accounts/add_work_case'
require_dependency 'accounts/adjust_delinquency_buckets'
require_dependency 'accounts/clear_delinquency'
require_dependency 'accounts/create'
require_dependency 'accounts/customer_service_rehab'
require_dependency 'accounts/get_chronicle_memos'
require_dependency 'accounts/get_credit_line_decision'
require_dependency 'accounts/get_payment_history'
require_dependency 'accounts/get_rewards_summary'
require_dependency 'accounts/get'
require_dependency 'accounts/issue_letter'
require_dependency 'accounts/lower_non_dq_mpd_amount'
require_dependency 'accounts/noint_method_override'
require_dependency 'accounts/non_receipt'
require_dependency 'accounts/partial_annual_fee_adjustment'
require_dependency 'accounts/search'
require_dependency 'accounts/set_external_status_reason_code'
require_dependency 'accounts/set_future_fixed_minimum_payment_amount'
require_dependency 'accounts/set_mpd_start_and_end_dates'
require_dependency 'accounts/set_valid_income_flag'
require_dependency 'accounts/simple_nonmon'
require_dependency 'accounts/stabilize_delinquency'
require_dependency 'accounts/update_ability_to_pay_max_credit_line'
require_dependency 'accounts/update_address'
require_dependency 'accounts/update_auto_reage_flag'
require_dependency 'accounts/update_credit_bureau_flag'
require_dependency 'accounts/update_credit_bureau_score'
require_dependency 'accounts/update_credit_limit'
require_dependency 'accounts/update_external_status'
require_dependency 'accounts/update_interest_accrual'
require_dependency 'accounts/update_late_fee_flag'
require_dependency 'accounts/update_loss_mitigation_indicator'
require_dependency 'accounts/update_minimum_payment_amount'
require_dependency 'accounts/update_next_auto_reage_date'
require_dependency 'accounts/update_past_reage_date'
require_dependency 'accounts/update_payment_history'
require_dependency 'accounts/update_prevent_charge_off_flag'
require_dependency 'accounts/update_pricing_strategy'
require_dependency 'accounts/update'
require_dependency 'credit_cards/activate'
require_dependency 'credit_cards/force_emboss'
require_dependency 'credit_cards/get_first_data_account_reference'
require_dependency 'credit_cards/set_authorization_block'
require_dependency 'credit_cards/update_fraud_behavior'
require_dependency 'credit_cards/update_fraud_strategy_group'
require_dependency 'credit_cards/update'
require_dependency 'customers/update_email_address'
require_dependency 'customers/update_name'
require_dependency 'customers/update_phone_number'
require_dependency 'customers/update'
require_dependency 'fraud_alerts/enroll'
require_dependency 'fraud_alerts/unenroll'
require_dependency 'statements/get_history'
require_dependency 'transactions/confirm_posted'
require_dependency 'transactions/get_authorizations'
require_dependency 'transactions/get_cycle'
require_dependency 'transactions/get_past'

module FdrGateway
  module Api
    class EndpointClassMap
      def self.for_key(key)
        endpoint_classes.fetch(key)
      end

      # rubocop:disable Metrics/MethodLength
      def self.endpoint_classes
        {
          'activate_credit_card' => CreditCards::Activate,
          'add_work_case' => Accounts::AddWorkCase,
          'adjust_delinquency_buckets' => Accounts::AdjustDelinquencyBuckets,
          'clear_delinquency' => Accounts::ClearDelinquency,
          'confirm_posted' => FdrGateway::Transactions::ConfirmPosted,
          'create_account' => Accounts::Create,
          'customer_service_rehab' => FdrGateway::Accounts::CustomerServiceRehab,
          'enroll_fraud_alerts' => FraudAlerts::Enroll,
          'force_emboss' => CreditCards::ForceEmboss,
          'get-chronicle-memos_account' => Accounts::GetChronicleMemos,
          'get_account' => Accounts::Get,
          'get_account_reference_by_card_number' => CreditCards::GetFirstDataAccountReference,
          'get_cycle_posted_transactions' => Transactions::GetCycle,
          'get_past_posted_transactions' => Transactions::GetPast,
          'get_payment_history' => Accounts::GetPaymentHistory,
          'get_pending_and_declined_transactions' => Transactions::GetAuthorizations,
          'get_statement_history' => Statements::GetHistory,
          'get_credit_line_decision' => Accounts::GetCreditLineDecision,
          'get_rewards_summary' => Accounts::GetRewardsSummary,
          'issue-letter_account' => Accounts::IssueLetter,
          'lower_non_dq_mpd_amount' => Accounts::LowerNonDqMpdAmount,
          'noint_method_override' => Accounts::NointMethodOverride,
          'non_receipt' => Accounts::NonReceipt,
          'set_external_status_reason_code' => Accounts::SetExternalStatusReasonCode,
          'update_external_status' => Accounts::UpdateExternalStatus,
          'partial_annual_fee_adjustment' => Accounts::PartialAnnualFeeAdjustment,
          'search_accounts' => Accounts::Search,
          'set_authorization_block' => CreditCards::SetAuthorizationBlock,
          'set_future_fixed_minimum_payment_amount' => Accounts::SetFutureFixedMinimumPaymentAmount,
          'set_mpd_start_and_end_dates' => Accounts::SetMpdStartAndEndDates,
          'set_valid_income_flag' => Accounts::SetValidIncomeFlag,
          'simplenonmon_account' => Accounts::SimpleNonmon,
          'stabilize_delinquency' => Accounts::StabilizeDelinquency,
          'unenroll_fraud_alerts' => FraudAlerts::Unenroll,
          'update_ability_to_pay_max_credit_line' => Accounts::UpdateAbilityToPayMaxCreditLine,
          'update_account' => Accounts::Update,
          'update_address' => Accounts::UpdateAddress,
          'update_auto_reage_flag' => Accounts::UpdateAutoReageFlag,
          'update_next_auto_reage_date' => Accounts::UpdateNextAutoReageDate,
          'update_past_reage_date' => Accounts::UpdatePastReageDate,
          'update_credit_bureau_flag' => Accounts::UpdateCreditBureauFlag,
          'update_credit_bureau_score' => Accounts::UpdateCreditBureauScore,
          'update_credit_card' => CreditCards::Update,
          'update_credit_limit' => Accounts::UpdateCreditLimit,
          'update_customer' => Customers::Update,
          'update_email_address' => Customers::UpdateEmailAddress,
          'update_fraud_behavior' => CreditCards::UpdateFraudBehavior,
          'update_fraud_strategy_group' => CreditCards::UpdateFraudStrategyGroup,
          'update_interest_accrual' => Accounts::UpdateInterestAccrual,
          'update_late_fee_flag' => Accounts::UpdateLateFeeFlag,
          'update_loss_mitigation_indicator' => Accounts::UpdateLossMitigationIndicator,
          'update_minimum_payment_amount' => Accounts::UpdateMinimumPaymentAmount,
          'update_name' => Customers::UpdateName,
          'update_payment_history' => Accounts::UpdatePaymentHistory,
          'update_phone_number' => Customers::UpdatePhoneNumber,
          'update_prevent_charge_off_flag' => Accounts::UpdatePreventChargeOffFlag,
          'update_pricing_strategy' => Accounts::UpdatePricingStrategy
        }
      end
      # rubocop:enable Metrics/MethodLength
    end
  end
end
