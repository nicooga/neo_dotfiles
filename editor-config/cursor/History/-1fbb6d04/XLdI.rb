require_dependency "env"
require "faraday"

module AvantBasicGateway
  class Request
    include Actionizer
    include CreditCardLogger::Breadcrumbs

    inputs_for(:call) do
      required :path, type: String, null: false
      required :body, type: Hash, null: false
    end
    def call
      connection = Faraday.new(
        url: Env.avant_basic_host_url,
        request: {
          open_timeout: Env.downstream_timeout,
          timeout: Env.downstream_timeout
        }
      )

      response = connection.post { |request|
        request.url input[:path]
        request.headers["Client-Version"] = Env.avant_basic_client_version
        request.headers["Content-Type"] = "application/json"
        request.body = Oj.dump(input[:body], mode: :json) if input[:body]
      }.tap(&method(:create_breadcrumb))

      OpenStruct.new(body: response.body, status: response.status)
    end

    def create_breadcrumb(response)
      breadcrumb_http_from_faraday_response(
        response,
        category: "AvantBasicGateway",
        data: input[:body]
      )
    end
  end
end
