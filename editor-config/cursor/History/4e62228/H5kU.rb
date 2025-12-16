require "action_runner"
require "avant/email"
require "avant/email_logger"
require "templateflow_engine/client"

require_relative "send_email_async"
require_relative "helpers/in_transaction_helper"

# An ActionRunner::Action that generates a body and sends an email.
#
# inputs:
# @param [Symbol] email - the email whose config drives the sending.
# @param [Bool] async - whether or not to run async. default true.
# @param [Verbalize::Action] attachment_renderer - generate attachments
# @param [Hash] attachment_renderer_inputs - attachment renderer inputs
# @param [String|Array] bcc - as per standard email
# @param [String|Array] cc - as per standard email
# @param [Hash] data - A hash of data to fill the template in with.
# @param [Bool] deliver - if true, calls deliver_now! defaults to true.
# @param [Bool] force - ignore email policies; defaults to false
# @param [String|Array] bypass - "all" to bypass all policies, or list of policies to bypass
# @param [String] from - as per standard email
# @param [Hash] headers - as per standard email
# @param [Hash] renderer_inputs - inputs to pass into Data Renderer
# @param [String] reply_to - as per standard email
# @param [String|Array] to - as per standard email
# @param [EmailLog] email_log - the log entry to record for the mailer.
#
# @param [String] body - body by string
# @param [String] templateflow_uuid - body by TemplateFlow

# outputs:
# @return [Avant::MessageTracker] message - the message being sent if sync
# @return [String] email_job_jid - the JID of the Sidekiq job if async
# @return [Verbalize::Success|Verbalize::Failure] The action results.
module Avant
  module Actions
    class SendEmail
      include ActionRunner::Action

      class MissingInputsError < Amount::Event::ErrorWithContext; end
      class Failure < Amount::Event::ErrorWithContext; end

      input :email, optional: %i[
        from to reply_to cc bcc
        subject headers body
        force
        bypass

        attachment_renderer attachment_renderers
        after_action

        product customer_application customer merchant tenant
        templateflow_uuid

        async do_retry delay_minutes

        email_log
      ].concat([{ # default values hash
        attachment_renderer_inputs: {},
        client: -> { TemplateflowEngine::Client },
        data: {},
        deliver: true,
        high_priority: false,
        metadata: {},
        renderer_inputs: {},
      }])

      output :message, optional: %i[email_job_jid email_log_uuid]

      def valid_customer_email?
        customer.errors[:email].empty? && Avant::Email::Address.is_valid?(customer.email)
      end

      def call
        return if Avant::Env.turn_off_emails?

        context = {
          email_log_id: email_log&.id,
          templateflow_uuid: template_uuid,
          prefilled_data: data
        }

        Amount::Event::Alert.scope(:email_send, tags: tags, context: context) do
          generate_email
        rescue UncaughtThrowError => e
          # don't re-fail on our own explicit fail!
          raise if e.tag == Verbalize::THROWN_SYMBOL
        rescue Verbalize::Error => e
          if e.message.match?(/Invalid command or cannot parse to address/i)
            @customer.update_attribute("bad_email", true)
          else
            raise e
          end
        rescue => e # if templateflow goes down, e.g., fail the call.
          fail!(e) # luckily the scope functionality works in the rescue block!
        end
      end

      # this is an insane verbalize patch used for a single test where an instance
      # of the action is being constructed explicitly.
      def defaults
        self.class.defaults
      end

      private

      def generate_email
        if customer && !customer.bad_email? && !valid_customer_email?
          customer.update_attribute("bad_email", true)
        end

        if !force && undeliverable?
          error = Amount::Event::ErrorWithContext.new("Email delivered or bounced")
          Amount::Event::Alert.error(error)
          return
        end

        # initialize as false; if we fail, we'll retry w/true
        @force_async = false unless defined?(@force_async)

        if is_async?
          send_async
        else
          catch(:had_failure) { send_sync }
        end
        log_templateflow_reference!
        self.email_log_uuid = email_log&.uuid
      end

      def undeliverable?
        email_log&.delivered? || email_log&.bounced?
      end

      def fail!(failure_value)
        error = Failure.new(failure_value, tags: tags, send_email_inputs: serialized_input_values)

        # if we've already retried or we were just going to create a job, then
        # that's a serious failure and we have to treat it like a typical failure.
        if !do_retry || is_async?
          Amount::Event::Alert.error(error)
          # from Verbalize::Action
          throw(Verbalize::THROWN_SYMBOL, failure_value)
        end

        # otherwise, we can re-try asynchronously (i.e. instead of sending, we
        # will schedule a job).

        # to avoid losing one-off errors that might be handled by retries, we
        # treat errors that are going to be retried as debug-level to avoid
        # too much noise in sentry/datadog (since we can filter these values out).
        Amount::Event::Alert.debug_exception(error)

        @force_async = true # this will cause is_async? to be true for the above
        call

        # even if the `call` above succeeds, we had an original failure which we
        # now have to continue execution on, meaning we throw this exception so
        # that we are being consistent in the behavior of #fail!.
        throw :had_failure
      end

      def tags
        @tags ||= {
          email_key: email,
          customer_application_id: customer_application&.id,
          customer_id: customer&.id
        }.tap do |t|
          t[:product] = "#{product.class}##{product.id}" if product
        end.compact
      end

      def correlation_id
        email_log&.uuid || customer_application&.uuid || product&.uuid
      end

      # behavior

      def send_async
        self.message = nil
        self.email_job_jid = Helpers::InTransactionHelper.trigger!(
          commit: method(:perform_send_async), rollback: method(:rollback)
        ) # could be ":waiting_for_commit"
      end

      def perform_send_async
        ActiveSupport::Notifications.instrument(NotificationEvents::EMAIL_SENT_ASYNC_ENQUEUE, {
          correlation_id: correlation_id,
        }.merge(input_values)) do
          SendEmailAsync.call!(input_values)
        end
      end

      def send_sync
        self.message = Helpers::InTransactionHelper.trigger!(
          commit: method(:perform_send_sync), rollback: method(:rollback)
        )
      end

      def perform_send_sync
        ActiveSupport::Notifications.instrument(NotificationEvents::EMAIL_SENT_SYNC_ENQUEUE, {
          correlation_id: correlation_id,
        }.merge(input_values)) do
          Amount::Event::Alert.info("Sending sync email for customer_application: #{customer_application&.id}")

          if email_log
            email_log.template_variables_json_string = Oj.dump(rendered_data, mode: :compat)
          end

          GlobalMailer.send_email(
            to: to || config[:to] || rendered_data[:email],
            from: from || config[:from],
            reply_to: reply_to || config[:reply_to],
            cc: cc || config[:cc],
            bcc: bcc || config[:bcc],
            subject: rendered_subject,
            # don't let passed-in "false" override configged true
            force: force.nil? ? config[:force] : force,
            bypass: bypass || config[:bypass] || [],
            body: render_body,

            headers: (headers || config[:headers] || {}).merge(extra_headers),
            attachments: render_attachments,

            customer_id: rendered_data[:customer_id],
            merchant_id: merchant&.id,
            use_secondary_smtp: config[:use_secondary_smtp],
            email_log: email_log,
            metadata: all_metadata,
          ).tap do |msg|
            if deliver
              msg.deliver_now!
              if !config[:after_action_only_on_delivery] || email_log&.reload&.delivered?
                run_after_action(msg)
              end
            end
          end
        end
      end

      def rollback
        msg = "Tried to send email #{email} but transaction rolled back."
        Amount::Event::Alert.info(msg)
      end

      def all_metadata
        @all_metadata ||= {
          "email"                     => email,

          "noaa_type"                 => data&.[](:noaa_type),
          "noaa_reasons"              => data&.[](:noaa_reasons),

          "product_type"              => product&.class&.name,
          "product_uuid"              => product&.uuid,
          "customer_application_uuid" => customer_application&.uuid,
          "mailer_class"              => "GlobalMailer",
          "mailer_template"           => "send_email",

          **(renderer_inputs || {}).map { |k, v| v.respond_to?(:uuid) ? [:"#{k}_uuid", v&.uuid] : [:"#{k}_id", v&.id] }.to_h.compact,

          **(metadata&.deep_symbolize_keys || {})
        }.compact.deep_stringify_keys
      end

      def config
        @config ||= begin
          config_source = (product || customer_application)&.config || AppConfig
          config_source.emails[email].to_h
        end
      end

      def input_values
        self.class.inputs.map do |i|
          value = instance_variable_get "@#{i}"
          [i, value]
        end.to_h
      end

      def serialized_input_values
        input_values.map do |k, v|
          if v.respond_to?(:uuid)
            [:"#{k}_uuid", v.uuid]
          elsif v.is_a?(Module)
            [k, v.name]
          else
            [k, v]
          end
        end.to_h
      end

      # actions

      def variables_list
        return [] unless template_uuid
        # We don't want to fail twice for the same reason
        return [] if @data_results&.failure?

        # lazily require here as it relies on REDIS configuration for
        # virtual_column
        require "avant/templateflow/get_variables"

        @data_results ||= Avant::Templateflow::GetVariables.call(uuid: template_uuid, client: client)
        fail!(@data_results.failure) if @data_results.failure?

        (@data_results.value + subject_variable_keys).uniq || []
      end

      def subject_variable_keys
        @subject_variable_keys ||= begin
          subject_string = subject || config[:subject] || ""
          subject_string.scan(/%{(?<var>.*?)}/).flatten.map { |s| s.to_sym }
        end
      end

      def render_data
        # note that we can't extract this out yet because we have
        # emails which are not using templateflow, and thus we still have to
        # render data externally
        data_list = variables_list.map(&:to_sym)

        all_renderer_inputs = renderer_inputs.merge({
          product: product,
          customer_application: customer_application,
          customer: customer,
          merchant: merchant,
          data_list: data_list,
          exclude_data_list: data.keys
        }).merge(config[:renderer_inputs] || {})

        data_results = ::Avant::Email::DataRenderer.call(**all_renderer_inputs)
        fail!(data_results.failure) if data_results.failure?

        data_results.value
      end

      def rendered_data
        @rendered_data ||= data.merge(render_data)
      end

      def render_body
        return local_body if local_body.present?
        return body_from_templateflow if body_from_templateflow.present?

        fail!("Failed to create body for #{email}!")
      end

      def local_body
        body || config[:body]
      end

      def rendered_subject
        return local_subject if local_subject.present?
        return subject_from_templateflow if subject_from_templateflow.present?

        fail!("Failed to create subject for #{email}!")
      end

      def local_subject
        @local_subject ||= begin
          subject_string = subject || config[:subject] || ""

          if subject_variable_keys.any?
            subject_string = subject_string % rendered_data
          end

          subject_string
        end
      end

      def subject_from_templateflow
        templateflow_response.dig(:optional_fields, :subject) if template_uuid
      end

      def body_from_templateflow
        templateflow_response[:html] if template_uuid
      end

      def templateflow_response
        @templateflow_response ||= Avant::Templateflow::CreateDocument.call(
          client: client,
          uuid: template_uuid,
          data: rendered_data,
          product: product,
          customer_application: customer_application
        )

        if @templateflow_response.failed?
          # Since we only request a response from Templateflow if-and-only-if there is not a local subject or body
          # provided, we have no reason to retry the call and should only fail
          @do_retry = false
          fail!(@templateflow_response.failure)
        end

        @templateflow_response.value
      end

      def log_templateflow_reference!
        # return if Templateflow was not/will not be used for this email
        return if !template_uuid || (local_subject && local_body)

        # return if we did not get an expected response from Templateflow or the email log could not be generated
        return unless templateflow_response[:template_version_uuid] && email_log

        return if defined?(@templateflow_response_logged)

        TemplateFlowLog.create(
          reference: email_log,
          template_version_uuid: templateflow_response[:template_version_uuid],
          all_version_uuids: templateflow_response[:all_version_uuids] || []
        )

        @templateflow_response_logged = true
      rescue => e
        # alert, but do not block behavior.
        Amount::Event::Alert.error(e)
      end

      def extra_headers
        {}.tap do |extra_headers|
          if product
            extra_headers["X-Product-Class"] = product.class.to_s
            extra_headers["X-Product-Uuid"] = product.uuid
          end

          if customer_application
            extra_headers["X-Application-Uuid"] = customer_application.uuid
          end

          if email_log
            extra_headers["X-Email-Log-Uuid"] = email_log.uuid
          end

          renderer_inputs.each do |type, input|
            if input.respond_to?(:uuid)
              extra_headers["X-#{type.capitalize}-Uuid"] = input.uuid
            elsif input.respond_to?(:id)
              extra_headers["X-#{type.capitalize}-Id"] = input.id
            end
          end

          # The above headers will appear in legacy webhooks. Mailgun's V3 webhooks require them all to go
          # in a special header called X-Mailgun-Variables, and will ignore the others.
          if extra_headers.any?
            extra_headers['X-Mailgun-Variables'] = Oj.dump(extra_headers, mode: :compat)
          end
        end
      end

      def render_attachments
        renderers = []
        renderers.concat config[:attachment_renderers] if config[:attachment_renderers]
        renderers << config[:attachment_renderer] if config[:attachment_renderer]

        renderer_inputs = {
          product: product,
          customer_application: customer_application,
          customer: customer,
          email_log: email_log
        }.merge!(attachment_renderer_inputs || {})

        renderers.reduce({}) do |acc, renderer|
          renderer = renderer.constantize if renderer.is_a?(String)
          final_inputs = renderer_inputs.slice(*renderer.inputs)
          outputs = renderer.call!(**final_inputs)
          acc.merge(outputs)
        end
      end

      def run_after_action(message)
        after_interactor = config[:after_action]&.constantize

        if after_interactor
          after_inputs = {message: message}   # we want the message...
            .merge(input_values)                 # any local overrides...
            .merge(rendered_data.symbolize_keys) # and any relevant data...
            .slice(*after_interactor.inputs)      # that the action may need.

          missing_inputs = after_interactor.required_inputs - after_inputs.keys
          if missing_inputs.any?
            dispatch_alert(missing_inputs)
            return
          end

          after_interactor.call(**after_inputs)
        end
      end

      def dispatch_alert(missing_inputs)
        error = MissingInputsError.new("Failed to run After Action", tags: all_metadata, email: email, missing_inputs: missing_inputs)
        error.set_backtrace(caller)
        Amount::Event::Alert.error(error)
      end

      # defaults

      # Whether or not we should just trigger a job to run to process the email
      # send. If true, instead of generating and delivering the email, we simply
      # schedule a sidekiq job.
      def is_async?
        return false if Avant::Env.synchronous_emails?
        return true if @force_async

        if async.nil? # not passed in
          if config[:async].nil? # and not defined
            true # default to true
          elsif delay_minutes
            true
          else
            config[:async]
          end
        else # passed in
          async
        end
      end

      def do_retry
        return false if Avant::Env.synchronous_emails?
        return true if @do_retry.nil?
        @do_retry
      end

      # create an email log if we're not explicitly passing one in.
      def email_log
        return if config[:not_customer_facing]

        @email_log ||= begin
          message = OpenStruct.new(
            to:          to || config[:to] || data[:email] || calculated_customer&.email,
            subject:     async ? (subject || config[:subject] || "[#{email_identifier.titleize}]") : rendered_subject,
            customer:    calculated_customer,
            customer_id: calculated_customer&.id,
            merchant_id: merchant&.id,
            tenant_id:   tenant&.id,
            metadata:    all_metadata
          )

          ::Avant::EmailLogger.create_log(message).tap do |log|
            if log # apparently EmailLogger.create_log doesn't always create a log
              log.prefilled_data = Oj.dump(data, mode: :compat)
            end
          end
        end
      end

      # same as Avant::Email::DataRenderer#_customer
      def calculated_customer
        @calculated_customer ||= product&.customer ||
          customer_application&.customer ||
          customer
      end

      def data
        @data ||= {}
      end

      def template_uuid
        return @template_uuid if defined?(@template_uuid)
        @template_uuid = templateflow_uuid || config[:templateflow_uuid]
      end
    end
  end
end
