# This class orchestrates the processing of a credit line increase request,
# including eligibility checks, credit report updates, decision making,
# and execution of associated side-effects such as updating credit limits,
# handling declines, and issuing notifications.
require "base64"
require_dependency "oj"
require_dependency "env"

module FdrGateway
  class Base
    include Actionizer
    include CreditCardLogger::Breadcrumbs

    #===============================================================================#
    #                               CUSTOM ERRORS                                   #
    #===============================================================================#

    class FdrGatewayBadGatewayError < RuntimeError; end

    class FdrGatewayCallError < RuntimeError; end

    class FdrGatewayClientError < RuntimeError; end

    class FdrGatewayServerError < RuntimeError; end

    class FdrGatewayTimeoutError < RuntimeError; end

    #===============================================================================#
    #                                  CONSTANTS                                    #
    #===============================================================================#

    #################################################################################
    #  @!group Failure Slugs                                                       ##
    ##                                                                             ##

    FDR_GATEWAY_FAILURE = "fdr_gateway_failure".freeze
    FDR_GATEWAY_TIMEOUT = "fdr_gateway_timeout".freeze

    ##                                                                             ##
    #  @!endgroup Failure Slugs                                                    ##
    #################################################################################

    #################################################################################
    #  @!group HTTP Payload Constants                                              ##
    ##                                                                             ##

    # Generic Call Endpoint
    ENDPOINT_CALL = "/call".freeze
    # Generic Async Call Endpoint
    ENDPOINT_ASYNC_CALL = "/async_call".freeze

    # `Content-Type` header
    CONTENT_TYPE = "Content-Type".freeze
    # `Content-Type` header value
    APPLICATION_JSON = "application/json".freeze

    # 504 Gateway Timeout message in response body
    GATEWAY_TIMEOUT = "504 Gateway".freeze
    # 502 Bad Gateway message in response body
    BAD_GATEWAY = "502 Bad Gateway".freeze

    ##                                                                             ##
    #  @!endgroup HTTP Payload Constants                                           ##
    #################################################################################

    #################################################################################
    #  @!group Logging Constants                                                   ##
    ##                                                                             ##

    # APM tracing resource name
    TRACE_RESOURCE = "FdrGateway::Base.fdr_gateway_call".freeze
    # POST HTTP Method
    POST = "POST".freeze
    # PUT HTTP Method
    PUT = "PUT".freeze
    # GET HTTP Method
    GET = "GET".freeze
    # Timeout Reason for Sentry breadcrumbs
    REASON_TIMEOUT = "Timeout".freeze

    # Unexpected Error Message
    UNEXPECTED_ERROR = "Exception raised during FDR Gateway call".freeze
    # Error message for when JSON parsing fails
    PARSING_ERROR = "Error parsing response from FdrGateway".freeze
    # Error message for when FDR Gateway responds with a 4XX
    CLIENT_ERROR = "Failed to complete FDR Gateway request!".freeze

    ##                                                                             ##
    #  @!endgroup Logging Constants                                                ##
    #################################################################################

    #===============================================================================#
    #                                  ATTRIBUTES                                   #
    #===============================================================================#

    # The action we are calling in FDR Gateway
    # @return [String]
    attr_reader :endpoint_key

    # Whether or not we're hitting the async generic_endpoint or the normal one
    # @return [Boolean]
    attr_reader :async

    # Whether or not we're using the generic endpoints (`"/call" or `"/async_call"`)
    #
    # Otherwise, we use {#endpoint_key} as the actual REST endpoint to hit
    #
    # @return [Boolean]
    attr_reader :generic_endpoint

    #===============================================================================#
    #                                  ENTRYPOINT                                   #
    #===============================================================================#

    def fdr_gateway_call(endpoint_key, message_params, async: false, generic_endpoint: true)
      @endpoint_key = endpoint_key
      @async = async
      @generic_endpoint = generic_endpoint
      @http_method = POST

      with_logging_and_error_handling { conn_response(message_params) }
    end

    # Send a PUT command to FDR Gateway
    def fdr_gateway_put(endpoint, message_params)
      @endpoint_key = endpoint_key
      @http_method = PUT

      with_logging_and_error_handling { conn_put endpoint, message_params }
    end

    # Send a GET command to FDR Gateway
    def fdr_gateway_get(endpoint_key)
      @endpoint_key = endpoint_key
      @http_method = GET

      with_logging_and_error_handling { conn_get endpoint_key }
    end

    private

    #===============================================================================#
    #                               HELPER METHODS                                  #
    #===============================================================================#

    #################################################################################
    #  @!group Happy Path HTTP Helpers                                             ##
    #                                                                              ##
    #  Happy path helpers for preparing, sending, and parsing the REST call        ##
    ##                                                                             ##

    # Main helper/coordinator method for sending request
    def with_logging_and_error_handling
      Tracing.trace(TRACE_RESOURCE, resource: endpoint_key) do |span|
        response = yield
        log_response(response)

        body = parse_response(response)

        return body unless (400..599).cover?(response.status)

        parse_failed_response(response, body, endpoint_key)
      rescue Faraday::ConnectionFailed, Faraday::TimeoutError => error
        timeout_error! error, response: response
      rescue Actionizer::Failure => error
        # Need this because Actioinizer::Failure < StandardError
        # (i.e. fail! would get caught by the rescue => e below)
        raise error
      rescue => error
        unexpected_error! error, response: response
      end
    end

    def conn
      Faraday.new(
        url: Env.fdr_gateway_url,
        request: {
          open_timeout: Env.downstream_timeout,
          timeout: Env.downstream_timeout
        }
      )
    end

    # Do a POST request, possibly to the generic endpoint
    def conn_response(message_params)
      url, message_body = assign_parameters(message_params)

      conn.post do |request|
        request.url url
        request.body = Oj.dump(message_body, mode: :compat)
        request.headers[CONTENT_TYPE] = APPLICATION_JSON
      end
    end

    # Do a PUT request
    def conn_put(endpoint, message_params)
      conn.put do |request|
        request.url endpoint
        request.body = Oj.dump(message_params, mode: :compat)
        request.headers[CONTENT_TYPE] = APPLICATION_JSON
      end
    end

    # Do a GET request
    def conn_get(endpoint_key)
      conn.get do |request|
        request.url endpoint_key
        request.headers[CONTENT_TYPE] = APPLICATION_JSON
      end
    end

    def assign_parameters(message_params)
      if generic_endpoint
        url = async ? ENDPOINT_ASYNC_CALL : ENDPOINT_CALL
        message_body = {endpoint_key: endpoint_key, message_body: message_params}
      else
        url = "/#{endpoint_key}"
        message_body = message_params
      end
      [url, message_body]
    end

    # Parse the response object
    # @param response [Faraday::Response]
    def parse_response(response)
      return {} if response.body.blank?

      Oj.load(response.body, mode: :compat, symbol_keys: true)
    rescue => error
      parsing_error! error, response: response
    end

    ##                                                                             ##
    #  @!endgroup Happy Path HTTP Helpers                                          ##
    #################################################################################

    #################################################################################
    #  @!group Rescue Helpers                                                      ##
    #                                                                              ##
    #  Methods to handle errors caught by `rescue` statements                      ##
    ##                                                                             ##

    # Handle an unexpected error
    #
    # @raise [Actionizer::Failure]
    def unexpected_error!(error, response:)
      Tracing.add_context(
        error: true, error_message: error.message, error_type: error.class.name
      )
      error_message = UNEXPECTED_ERROR

      context = {input: prevent_context_offuscation(input.to_h)}
      tags = {class_name: self.class.name, endpoint_key: endpoint_key}

      handle_error(
        FdrGatewayCallError.new(error_message),
        response: response,
        inner_error: error,
        tags: tags,
        context: context
      )
    end

    # Handle an error from JSON parsing the response body
    #
    # @raise [Actionizer::Failure]
    def parsing_error!(error, response:)
      Tracing.add_context(
        error: true, error_message: error.message, error_type: error.class.name
      )

      context = {input: prevent_context_offuscation(input.to_h)}
      tags = {class_name: self.class.name, endpoint_key: endpoint_key}

      handle_error(
        parse_error(response, error: error, endpoint_key: endpoint_key),
        response: response,
        inner_error: error,
        tags: tags,
        context: context
      )
    end

    # Handle an error from the request to FDR Gateway timing out
    #
    # @raise [Actionizer::Failure]
    def timeout_error!(error, response:)
      CreditCardLogger::Stats.increment(
        FDR_GATEWAY_TIMEOUT, resource: endpoint_key
      )

      create_timeout_breadcrumb

      fail!(
        error: :fdr_gateway_timeout,
        error_code: FDR_GATEWAY_FAILURE,
        response: response,
        exception: error
      )
    end

    ##                                                                             ##
    #  @!endgroup Rescue Helpers                                                   ##
    #################################################################################

    #################################################################################
    #  @!group Sad Path Helpers                                                    ##
    #                                                                              ##
    #  Methods to interpret exceptions and bad repsponses, log them, and convert   ##
    #  them to Actionizer failures.                                                ##
    ##                                                                             ##

    # Log an exception then convert it into a Actionizer failure
    def handle_error(error, response: nil, inner_error: nil, tags: {}, context: {})
      error_context = context.merge(
        {response_body: response&.body, inner_error: inner_error}.compact
      )

      CreditCardLogger.error(error, error_context, tags)

      fail!(
        error: error.message,
        error_code: FDR_GATEWAY_FAILURE,
        response: response
      )
    end

    # Interpret a sad response from FDR Gateway (not `2XX`)
    #
    # We create an error and then pass it to {#handle_error}
    def parse_failed_response(response, body, endpoint_key)
      if (400..499).cover?(response.status)
        error_message = body[:error] ||
          body.dig(endpoint_key.split("_").last.to_sym, :error) || CLIENT_ERROR
        handle_error(FdrGatewayClientError.new(error_message), response: response)
      elsif (500..599).cover?(response.status)
        error_message = I18n.t("error.fdr_gateway.server")
        handle_error(FdrGatewayServerError.new(error_message), response: response)
      end
    end

    # Interpret a response JSON parsing error
    #
    # @return [FdrGatewayBadGatewayError] if FDR Gateway responds with 502
    # @return [FdrGatewayCallError] if FDR Gateway respondes with something
    #   other than 502 or 504
    # @raise [Actionizer::Failure] with a timeout failure if FDR Gateway
    #   responds with 504
    def parse_error(response, error: nil, endpoint_key: nil)
      response_body = response&.body
      error_message = PARSING_ERROR
      if response_body&.include? GATEWAY_TIMEOUT
        # Handle timeouts from the server when they are html instead of an error
        # handled by faraday
        CreditCardLogger::Stats.increment(
          FDR_GATEWAY_TIMEOUT, resource: endpoint_key
        )

        fail!(
          error: :fdr_gateway_timeout,
          error_code: FDR_GATEWAY_FAILURE,
          response: response,
          exception: error
        )
      elsif response_body&.include? BAD_GATEWAY
        FdrGatewayBadGatewayError.new(error_message)
      else
        FdrGatewayCallError.new(error_message)
      end
    end

    # Override fail! to add info to the current APM trace
    # @raise [Actionizer::Failure]
    def fail!(**context)
      # In Tracing, `error` is a reserved context field. But it's also a common
      # context field in CC-API's usage of `Actionizer#fail!`
      #
      # Use dup so we can keep the original context for actionizer
      tracing_context = context.dup
      error_slug = tracing_context.delete(:error)
      tracing_context[:error_slug] = error_slug if error_slug

      # Remove Faraday response from tracing context, since it's a object with a lot of stuff
      # It's also redundant, because the net/http trace that's automatically
      # created will have relevant data
      response = tracing_context.delete(:response)

      Tracing.add_context(error: true, **tracing_context)

      super
    end

    ##                                                                             ##
    #  @!endgroup Sad Path Helpers                                                 ##
    #################################################################################

    #################################################################################
    #  @!group Logging Helpers                                                     ##
    #                                                                              ##
    #  Methods that soley have exist to perform or facilitate logging              ##
    ##                                                                             ##

    def log_response(response)
      # Add context to the APM span
      Tracing.add_context(
        async: async, status: response.status, generic_endpoint: generic_endpoint
      )

      # Add a Sentry breadcrumb
      breadcrumb_http_from_faraday_response(
        response,
        category: self.class.name.gsub("::", "."),
        data: {endpoint_key: endpoint_key}
      )
    end

    def prevent_context_offuscation(params)
      params.each_with_object({}) do |(k, v), h|
        h[k] = if k == :first_data_account_reference
          Base64.encode64(v.to_s)
        else
          v
        end
      end
    end

    def create_timeout_breadcrumb
      url = Env.fdr_gateway_url + (async ? ENDPOINT_ASYNC_CALL : ENDPOINT_CALL)
      breadcrumb_http(
        level: :warning,
        url: url,
        method: @http_method,
        status_code: 499,
        reason: REASON_TIMEOUT,
        category: self.class.name.gsub("::", "."),
        data: {endpoint_key: endpoint_key}
      )
    end

    ##                                                                             ##
    #  @!endgroup Logging Helpers                                                  ##
    #################################################################################
  end
end
