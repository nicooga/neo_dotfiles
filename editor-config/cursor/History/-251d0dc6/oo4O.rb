require_dependency "action/admin/s3_storage"
require_dependency "avant_basic_gateway/api"
require_dependency "persistence/account"
require_dependency "entity/account"
require_dependency "persistence/statement"
require_dependency "action/admin/statements/ingest_manifest"
require_dependency "action/statements/add_rider_if_applicable"
require_dependency "error/pagerduty_alert"

class NeedsOnCallError < StandardError; end

module Action
  module Admin
    # Callback interactor for ingesting statement slices
    #
    # @see #call
    class FinishSendStatements
      include Actionizer

      # Accounts with these external statuses are disqualified from receiving statements
      NO_SEND_STATEMENT_STATUSES = [
        Entity::Account::BANKRUPT,
        Entity::Account::STOLEN,
        Entity::Account::CHARGED_OFF
      ]

      # The format of outband S3 file name.
      #
      # The file contains the data we pass onto Avant Basic to send the statement emails.
      FULL_DATA_S3_KEY_FORMAT = "credit_card_batch/filtered_send_statement_emails/%s/%s/%i".freeze

      # @!group Rider Attachment Constants
      #

      # Incident key we use when paging due to rider attachment issues.
      #
      # Ideally, the using the same incident key will result in less noise.
      RIDER_ISSUE_INCIDENT_KEY_FORMAT = "send_statements-rider_issues-%s".freeze

      # Incident key we use when paging due to rider attachment issues.
      #
      # Ideally, the using the same incident key will result in less noise.
      RIDER_ISSUE_INCIDENT_MESSAGE = "Some statements that should have riders are missing them".freeze

      # Link to include in the Pagerduty alert
      RIDER_PAGERDUTY_LINKS = [{
        type: "link",
        href: "https://www.notion.so/avant/Statement-Riders-Failed-to-Attach-ed771f4d72c843fcbab9e6e8a67ccb77?pvs=4",
        text: "Notion Runbook"
      }]

      #
      # @!endgroup

      # Format of statement date coming from Garden
      #
      # Needed for statement rider attaching
      STATEMENT_DATE_STRING_FORMAT = "%m%d%y".freeze

      inputs_for(:call) do
        required :callback_endpoint_key, type: String
        required :accounts, type: Array
        required :failed_accounts, type: Array
        required :zip_file_name, type: String, null: true
        # Slice index will be a two digit string (e.g. "23", "04", "00")
        required :slice_index, type: String, null: true
        required :s3_key, type: String, null: false
        optional :s3_accounts, type: Array
      end

      # Finish processing the statement ingestion for a single slice.
      #
      # This method does the following:
      #
      #   1. Combines the account data we received from garden with the account data we received
      #      from FDR Gateway
      #   2. Filters out accounts with ineligible statuses (disqualification)
      #   3. Invalidates the statement cache for the remaining accounts
      #   4. Sends the qualified account data to Avant Basic for email sends
      #
      # In addition, it also works with {Admin::Statements::IngestManifest} to record the number of
      # disqualified and sent statements for this slice.
      #
      # @param callback_endpoint_key [String] no-op argument passed in directly by the FDR Gateway call
      # @param accounts [Array<Entity::Account>] the account data we received from FDR Gateway
      # @param failed_accounts [Array] a list of logs that explain why an account was not processed in FDR Gateway
      #   an example log would be: "Failure on {{first_data_account_reference}}: Error when connecting to First Data REST API"
      # @param zip_file_name [String] The name of the original statement zip that Fiserv sent
      #   us. It's used for monitoring the process
      # @param slice_index [String] Indicates which slice we are ingesting. There are 100 slices per
      #   zip and the index will be a two digit string (e.g. "23", "04", "00"). This is used for
      #   monitoring the process
      # @param s3_key [String] The key of the file containing the account information from garden
      # @param s3_accounts [Array<Hash>, nil] Optionally, the Garden data already extracted. This is
      #   used when the {StartSendStatements} calls this method directly, instead of using the
      #   callback mechanism.

      # @return [void]
      #
      # @see StartSendStatements#call The first half of this process
      def call
        return if s3_accounts.none?

        full_s3_key = format(
          FULL_DATA_S3_KEY_FORMAT,
          s3_accounts.first[:statement_date],
          s3_accounts.first[:first_data_account_reference][-2, 2],
          Time.current.to_i
        )

        record_disqualified_accounts!

        if full_data.none?
          CreditCardLogger.info("No statements sent for slice #{input[:s3_key]} -> #{full_s3_key}")
          record_sent_accounts!(0)

          return
        end

        full_data.each do |hash|
          Persistence::Statement.cache_clear!(method_name: :history, cache_param: hash[:id])
        end

        Action::S3Storage.set!(
          key: full_s3_key,
          value: {failed_accounts: input[:failed_accounts], accounts: full_data}
        )

        # We track this in the log monitor which will alert on-call: https://avant-eng.datadoghq.com/monitors/180864039
        if input[:failed_accounts].present?
          error = NeedsOnCallError.new("ALERT-#{Error::PagerdutyAlert::CREDIT_CARD_SERVICE}: Statement Ingestion Discrepancy")
          details = {
            zip_file_name: input[:zip_file_name],
            slice_index: input[:slice_index],
            s3_key: input[:s3_key],
            failed_accounts: input[:failed_accounts],
            runbook_link: "https://www.notion.so/avant/Credit-Card-Statements-Not-Sent-da1e6201b1cb41bca922099166a9458d"
          }
          # We track this in the log monitor which will alert on-call: https://avant-eng.datadoghq.com/monitors/180864039
          CreditCardLogger.error(error, **details)
        end

        CreditCardLogger.info("Sending statements for slice #{input[:s3_key]} -> #{full_s3_key}")

        AvantBasicGateway::Api.callback!(
          callback_endpoint_key: "send_statement_emails",
          s3_key: full_s3_key
        )

        record_sent_accounts!(full_data.count)

        page_if_rider_issues!
      end

      private

      # Calculate and log the number of statements we disqualified for this slice.
      #
      # @return [void]
      def record_disqualified_accounts!
        return unless input[:zip_file_name] && input[:slice_index]

        disqualified_accounts_count = input[:accounts].count - full_data.count

        Admin::Statements::IngestManifest.record_account_disqualification!(
          zip_file_name: input[:zip_file_name],
          disqualified_accounts_count: disqualified_accounts_count,
          slice_index: input[:slice_index],
          s3_key: input[:s3_key]
        )
      end

      # Log the number of statements we sent to Avant Basic for this slice.
      #
      # @param count [Integer] the number of statements sent
      #
      # @return [void]
      def record_sent_accounts!(count)
        return unless input[:zip_file_name] && input[:slice_index]

        Admin::Statements::IngestManifest.record_sent_accounts!(
          zip_file_name: input[:zip_file_name],
          sent_accounts_count: count,
          slice_index: input[:slice_index],
          s3_key: input[:s3_key]
        )
      end

      # The combination of Garden and FDR Gateway account data. Also does the filtering based on
      # status and rider attachment.
      #
      # We do this in one loop to save time.
      #
      # @return [Array<Hash>] the account data
      def full_data
        @full_data ||= s3_accounts.map do |hash|
          account = organized_accounts[hash[:first_data_account_reference]]

          next unless account

          next if NO_SEND_STATEMENT_STATUSES.include?(account.external_status)

          # client_classification_7_code having a non-blank value means that we should try
          # attaching a statement rider.
          attach_rider(account, s3_account: hash) if account.client_classification_7_code.present?

          merge_accounts(account, s3_account: hash)
        end.compact
      end

      # Calls {Action::Statements::AddRiderIfApplicable} for an account.
      #
      # If this fails, it means we should have attached a rider but didn't.
      def attach_rider(account, s3_account:)
        rider_result = Action::Statements::AddRiderIfApplicable.call(
          account: account,
          statement_date: Date.strptime(s3_account[:statement_date], STATEMENT_DATE_STRING_FORMAT)
        )

        unless rider_result.success?
          missing_rider_accounts << rider_result.to_h.merge(
            {account_id: account.id},
            s3_account.except(:first_data_account_reference)
          )
        end
      end

      # List of accounts that we try to attach riders to, but failed.
      def missing_rider_accounts
        @missing_rider_accounts ||= []
      end

      def merge_accounts(account, s3_account:)
        autopay_plan = autopay_plans.fetch(account.id, []).first

        s3_account[:id] = account.id
        s3_account[:autopay] = autopay_plan&.status
        s3_account[:autopay_strategy] = autopay_plan&.strategy
        s3_account[:last_statement_balance] = Money.new(account.last_statement_balance_cents).to_f
        s3_account[:min_pay_due] = Money.new(account.minimum_payment_due_cents).to_f
        s3_account[:payment_due_date] = account.minimum_payment_due_date.to_s

        s3_account
      end

      def organized_accounts
        @organized_accounts ||= input[:accounts].each_with_object({}) do |account, my_hash|
          my_hash[account.first_data_account_reference] = account
        end
      end

      def autopay_plans
        @autopay_plans ||= Persistence::AutopayPlan.where!(
          account_id: input[:accounts].map(&:id)
        ).autopay_plans.group_by(&:account_id)
      end

      def s3_accounts
        @s3_accounts ||= input[:s3_accounts] || S3Storage.get!(key: input[:s3_key]).value[:accounts]
      end

      def page_if_rider_issues!
        return unless missing_rider_accounts.any?

        Error::PagerdutyAlert.call(
          service: Error::PagerdutyAlert::CREDIT_CARD_SERVICE,
          message: RIDER_ISSUE_INCIDENT_MESSAGE,
          incident_key: rider_issue_incident_key,
          details: {rider_issues: missing_rider_accounts},
          context: RIDER_PAGERDUTY_LINKS
        )
      end

      def rider_issue_incident_key
        @rider_issue_incident_key ||= format(
          RIDER_ISSUE_INCIDENT_KEY_FORMAT,
          s3_accounts.first[:statement_date]
        )
      end
    end
  end
end
