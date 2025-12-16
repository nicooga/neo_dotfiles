module SidekiqManualRetry
  # Special error class that gets filtered out by Sentry
  #
  # Inheriting from exception is intentional, to prevent accidentally rescues
  class SidekiqManualRetryError < StandardError
    # Optional exception to log when retries are exhausted
    #
    # Otherwise, {RetriesExhaustedError} will be logged
    #
    # @return [Exception]
    attr_accessor :source_exception
  end

  # Generic error for when we run out of retries
  class RetriesExhaustedError < StandardError; end

  extend self

  # Generic message for retry error
  RETRY = "RETRY"

  # Causes sidekiq to retry without polluting sentry.
  #
  # @note Make sure to log the actual failure somehow.
  #
  # @param source_exception [Exception] see {SidekiqManualRetryError#source_exception}
  #
  # @raise [SidekiqManualRetryError]
  def trigger_retry!(source_exception: nil)
    if source_exception 
      unless source_exception.is_a?(Exception)
        source_exception = StandardError.new(source_exception)
      end

      CreditCardLogger.warn("[SIDEKIQ][MANUAL_RETRY] #{source_exception}")
    end

    raise SidekiqManualRetryError.new(RETRY).tap { |e| e.source_exception = source_exception }
  end

  # Logic around handling the scenario where a worker runs out of retries
  #
  # @see https://dev.to/morinoko/sidekiq-s-sidekiqretriesexhausted-hook-3d0e
  def handle_retries_exhausted(job, exception)
    if exception.is_a?(SidekiqManualRetry::SidekiqManualRetryError)
      exception = if exception.source_exception
        exception.source_exception
      else
        SidekiqManualRetry::RetriesExhaustedError.new("Retries exhausted")
      end
    end

    CreditCardLogger.error(exception, job["args"].symbolize_keys)
  end
end
