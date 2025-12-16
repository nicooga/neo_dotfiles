require_dependency 'api/async_endpoint_worker_map'
require_dependency 'api/endpoint_class_map'
require_dependency 'constants'

module FdrGateway
  module Api
    class FirstDataSoapApi < Grape::API
      default_format :json

      helpers do
        def trace_endpoint_action(http_method)
          ::FdrGateway.tracer.trace(
            'web.request',
            service: 'fdr-gateway-call-api',
            resource: params.fetch('endpoint_key')
          ) do |span|
            span.set_tag('http.method', http_method)

            yield
          end
        end

        def derive_result_key(endpoint_key)
          endpoint_key.split('_')[1..-1].join('_')
        end

        def parse_result(result)
          return { derive_result_key(params.fetch('endpoint_key')) => result.payload } if result.success?

          error_message = "Couldn't perform '#{params.fetch('endpoint_key')}' action: #{result.error}"
          error_status = result.response_status || Constants.server_error

          Rails.logger.error(error_message)

          error!(error_message, error_status)
        end
      end

      desc 'Single First Data endpoint'
      params do
        requires :endpoint_key, type: String, values: EndpointClassMap.endpoint_classes.keys
        requires :message_params, type: JSON
      end
      get :call do
        trace_endpoint_action('GET') do
          endpoint_class = EndpointClassMap.for_key(params.fetch('endpoint_key'))
          result = endpoint_class.call(params.fetch('message_params').symbolize_keys)

          parse_result(result)
        end
      end

      desc 'The other Single First Data endpoint'
      params do
        requires :endpoint_key, type: String, values: EndpointClassMap.endpoint_classes.keys
        requires :message_body, type: Hash
      end
      post :call do
        trace_endpoint_action('POST') do
          endpoint_class = EndpointClassMap.for_key(params.fetch('endpoint_key'))
          result = endpoint_class.call(params.fetch('message_body').deep_symbolize_keys)

          parse_result(result)
        end
      end

      desc 'Async post endpoint'
      params do
        requires :endpoint_key, type: String, values: AsyncEndpointWorkerMap.endpoint_workers.keys
        requires :message_body, type: Hash do
          optional :callback_endpoint_key, type: String
          optional :callback, type: String
          optional :callback_metadata, type: Hash
        end
      end
      post :async_call do
        endpoint_worker = AsyncEndpointWorkerMap.for_key(params.fetch('endpoint_key'))
        job_id = endpoint_worker.perform_async(params.fetch('message_body').deep_symbolize_keys)
        Rails.logger.info("Async call to perform #{params.fetch('endpoint_key')} received and enqueued with JID: #{job_id}.")

        status 200
        { success: true }
      end
    end
  end
end
