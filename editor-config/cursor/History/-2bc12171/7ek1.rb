require_dependency "lib/action/accounts/issue_letter.rb"
require_dependency "sidekiq_manual_retry"

class IssueLetterWorker
  include Sidekiq::Worker
  sidekiq_options retry: 1

  sidekiq_retries_exhausted do |job, exception|
    SidekiqManualRetry.handle_retries_exhausted(job, exception)
  end

  # :nocov:
  sidekiq_retry_in do |count, exception|
    24.hours.to_i
  end
  # :nocov:

  def perform(args)
    result = Action::Accounts::IssueLetter.call(
      account_id: args["account_id"],
      letter_id: args["letter_id"]
    )

    if result.failure?
      SidekiqManualRetry.trigger_retry!(source_exception: StandardError.new(result.error))
    end
  end
end
po