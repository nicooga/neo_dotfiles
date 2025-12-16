require_dependency "env"
require_dependency "avant_basic_gateway/request"

module AvantBasicGateway
  class Api
    include Actionizer

    class AvantBasicGatewayError < StandardError; end

    class AvantBasicGatewayRetryError < StandardError; end

    RETRY_COUNT = 3
    RETRYABLE_STATUS_CODES = (502..503)

    inputs_for(:callback) do
      required :callback_endpoint_key, type: String
      required :s3_key, type: String
    end
    def callback
      path = "/secure/api/v1/async_callback"
      body = {
        callback_endpoint_key: input[:callback_endpoint_key],
        args: {
          s3_key: input[:s3_key]
        }
      }
      call_avant_basic(path, body)
    end

    inputs_for(:representment_eligible_accounts) do
      required :account_uuids, type: Array
    end
    def representment_eligible_accounts
      path = "/secure/api/v1/representment_eligible_accounts"
      body = {
        account_uuids: input[:account_uuids]
      }
      call_avant_basic(path, body)
    end

    inputs_for(:graphql) do
      required :variables, type: Hash
      required :query, type: String
      optional :stub_key
      optional :retry_on_fail
    end
    def graphql
      path = "/secure/api/v1/graphql_query"
      body = {
        query_string: input[:query],
        variables: input[:variables]
      }
      call_avant_basic(path, body, stub_key: input[:stub_key], retry_on_fail: input[:retry_on_fail])
    end

    # Retrieves fraud alerts for a customer from the Avant Basic API.
    # Queries the Avant Basic system to check for active duty status and fraud alert flags.
    #
    # @param customer_uuid [String] the UUID of the customer to check
    # @param correlation_id [String] an optional correlation ID for request tracking
    #
    # @return [Actionizer::Result] with output[:data] containing a Hash with keys:
    #   * :active_duty [Boolean] - Indicates if the customer has an active duty alert on file
    #   * :initial_fraud [Boolean] - Indicates if there is an initial fraud alert on file
    #   * :extended_fraud [Boolean] - Indicates if there is an extended fraud victim alert on file
    inputs_for(:fraud_alerts) do
      required :customer_uuid, type: String
      required :correlation_id, type: String
    end

    def fraud_alerts
      path = "/secure/api/v1/fraud_alerts"
      body = {
        customer_uuid: input[:customer_uuid],
        correlation_id: input[:correlation_id]
      }
      call_avant_basic(path, body)
    end

    private

    def call_avant_basic(path, body, stub_key: nil, retry_on_fail: false)
      response = nil

      @retry_count = 0

      begin
        if Env.stub_ab_api?
          output[:data] = AvantApiStubs.avant_basic_stub(stub_key)
          return
        end

        response = AvantBasicGateway::Request.call!(path: path, body: body)

        if RETRYABLE_STATUS_CODES.cover?(response.status) && @retry_count < RETRY_COUNT && retry_on_fail
          raise AvantBasicGatewayRetryError
        end

        output[:data] = parse_response(response)
      rescue Faraday::TimeoutError => e
        CreditCardLogger.warn(e, error_message: I18n.t("error.avant_basic_gateway.timeout"))

        fail!(error: e.message)
      rescue Actionizer::Failure => e
        raise e
      rescue AvantBasicGatewayRetryError
        @retry_count += 1

        # Exponential backoff
        sleep(2**@retry_count)

        retry
      rescue => e
        handle_exception(e, response&.body)
      end
    end

    def parse_response(response)
      if (400..599).cover?(response.status)
        handle_error(response.body)
      end

      json = Oj.load(response.body, symbol_keys: true)

      if json.key?(:errors)
        handle_error(response.body)
      end

      json.key?(:data) ? json[:data] : json
    end

    def handle_exception(exception, body)
      error_message = "Exception while connecting to Avant Basic"
      CreditCardLogger.error(error_message, inner_error: exception, response_body: body)
      fail!(error: error_message)
    end

    def handle_error(body)
      error_message = "Error connecting to Avant Basic: Received response with status code 500 internal server error from Avant Basic"
      CreditCardLogger.error(
        AvantBasicGatewayError.new(error_message),
        response_body: body,
        fingerprint: ["AvantBasicGatewayError"]
      )
      fail!(error: error_message)
    end
  end
end
