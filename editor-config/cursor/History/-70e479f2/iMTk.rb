require 'sidekiq/worker'
require 'avant/sidekiq/queues'
require 'avant/sidekiq/aggregate_with_offset'
require 'avant/sidekiq/delegate_job'
require 'avant/actions/helpers/in_transaction_helper'

module Avant
  module Sidekiq
    class Worker
      class NoJobError < StandardError
        attr_reader :sentry_fingerprint

        def initialize(msg, job_name)
          @sentry_fingerprint = job_name
          super(msg)
        end
      end

      class JobInitiatedInTransactionWarning < Amount::Event::ErrorWithContext
        def tags
          {job_class: @context[:job_class], job_name: @context[:job_name]}
        end

        def sentry_fingerprint
          [@context[:job_class], @context[:job_name]]
        end
      end

      include ::Sidekiq::Worker
      include Avant::Sidekiq::AggregateWithOffset
      include Avant::Sidekiq::DelegateJob

      attr_reader :options

      alias_method :uuid, :jid

      class_attribute :retryable_job_list
      self.retryable_job_list = []

      sidekiq_options queue: Avant::Sidekiq::Queues::NORMAL

      PoisonPillJobError = Class.new(Amount::Event::ErrorWithContext)

      # override this method
      def self.delay_in_transaction?(_method = nil)
        true
      end

      # @param [Hash] options - The options that will be sent to the job when
      #   performed. The key :job is important since it defines the method that
      #   will get called upon the job's execution. The rest of the keys will
      #   be available from the worker through the `options` hash.
      #
      # @return [String] The id (jid) that the created job received.
      def self.create(options)
        perform_async(options)
      end

      def self.perform_async(*args)
        return if jobs_are_disabled?

        if Avant::Actions::Helpers::InTransactionHelper.in_db_transaction?
          kwargs = args.first || {}
          job = kwargs[:job]

          begin
            if !kwargs.delete(:already_transaction_delayed) && (kwargs.delete(:transaction_delay) || delay_in_transaction?(job))
              kwargs[:already_transaction_delayed] = true
              # because the trigger block runs -after- we are no longer in a db transaction, this _should_
              # not loop. just in case though we'll inject an argument
              return Avant::Actions::Helpers::InTransactionHelper.trigger! do
                if (kwargs = args.first) # assignment intentional
                  kwargs.delete :already_transaction_delayed
                  kwargs.delete :transaction_delay
                end
                perform_async(*args)
              end
            else
              error = JobInitiatedInTransactionWarning.new(
                "Created Sidekiq Job #{"#{self}##{job}"} while in a transaction.",
                job_class: to_s,
                job_name: job
              )
              Amount::Event::Alert.warn(error)
            end
          rescue => e
            Amount::Event::Alert.debug_exception(e)
          end
        end

        super
      end

      def self.perform_in(*args)
        return if jobs_are_disabled?
        super
      end
      class << self; alias_method :perform_at, :perform_in; end

      def self.jobs_are_disabled?
        if self == Avant::Sidekiq::Worker
          !!@jobs_are_disabled
        else
          Avant::Sidekiq::Worker.jobs_are_disabled?
        end
      end

      def self.with_jobs_disabled(&block)
        if self == Avant::Sidekiq::Worker # called from a sub-worker
          begin
            @jobs_are_disabled = true
            yield
          ensure
            remove_instance_variable(:"@jobs_are_disabled")
          end
        else
          Avant::Sidekiq::Worker.with_jobs_disabled(&block)
        end
      end

      # this is just to track jobs that create other jobs
      # @return [String] uuid
      def self.create_with_parent(job, options)
        create(options.merge(parent_job_uuid: job.jid))
      end

      def self.retryable_jobs(*methods)
        retryable_job_list.push(*methods)
      end

      def self.retryable?(method_name)
        return false unless method_name
        retryable_job_list.include?(method_name.to_sym)
      end

      def self.cancel!(jid)
        ::Sidekiq.redis {|c| c.setex("cancelled-#{jid}", 86400, 1) }
      end

      def self.perform(options = {})
        new.perform(options)
      end

      def perform(options = {})
        options  = Oj.safe_load(options) if options.is_a?(String)
        @options = options.with_indifferent_access

        return if cancelled? || parent_cancelled? || batch_cancelled?

        if poisonous?
          Amount::Event::Alert.error(poison_pill_job_error)
          return
        end

        # Some jobs are implemented as private methods
        unless self.respond_to?(method_name.to_sym, true)
          raise NoJobError.new("Job #{method_name} does not exist on worker #{self.class.name}", full_job_name)
        end

        Rails.logger.info("Avant::Sidekiq::Worker calling #{full_job_name}(#{@options.inspect}) via Sidekiq")

        self.send(method_name.to_sym)
      end

      def class_name
        self.class.name.underscore
      end

      def method_name
        options['job']
      end

      def retryable?(method_name)
        self.class.retryable?(method_name)
      end

      def cancelled?
        job_was_cancelled?(jid)
      end

      def parent_cancelled?
        job_was_cancelled?(parent_jid)
      end

      def batch_cancelled?
        return false if bid.blank? # ensure this job is part of a Sidekiq::Batch
        !valid_within_batch?
      end

      def poisonous?
        super_fetch_recovery_count >= 3
      end

      private

      def super_fetch_recovery_count
        ::Sidekiq.redis{ |c| c.get("super_fetch_recoveries_#{jid}") }&.to_i || 0
      end

      def job_was_cancelled?(uuid)
        uuid.present? && ::Sidekiq.redis{ |c| c.exists("cancelled-#{uuid}") }
      end

      def full_job_name
        "#{self.class.name}##{method_name}"
      end

      def parent_jid
        options['parent_job_uuid']
      end

      def poison_pill_job_error
        PoisonPillJobError.new(
          "terminating poison pill sidekiq job",
          jid: jid,
          worker_class: self.class.name,
          worker_options: options,
          super_fetch_recovery_count: super_fetch_recovery_count
        )
      end
    end
  end
end
