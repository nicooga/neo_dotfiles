require_dependency 'certs'
require_dependency 'constants'
require_dependency 'env'
require_dependency 'security_header'
require_dependency 'security/encryption'

# rubocop:disable Metrics/ClassLength, Metrics/AbcSize,
module FdrGateway
  class BaseClient
    include Actionizer
    include Security::Encryption

    SUCCESS_MESSAGE_CODE = '0'

    def namespace
      fail NotImplementedError
    end

    def action
      fail NotImplementedError
    end

    def operation
      action.underscore.to_sym
    end

    def endpoint
      action
    end

    def make_client_call(message, generic_id, retry_call = true)
      response = client.call(operation, message: message, soap_header: security_header)

      if response_considered_success?(response)
        return response
      end

      @last_fdr_error_code = extract_fdr_error_code(response)

      if retry_call
        begin
          return make_client_call(message, generic_id, false)
        rescue Actionizer::Failure => e
          log_and_capture_error(message, response.body.to_s)
          fail!(error: e.message, response_status: response_status)
        end
      end

      fail!(error: failure_message, response_status: response_status)
    rescue Net::OpenTimeout, Net::ReadTimeout
      error_message = 'Timeout when attempting to call First Data'
      Raven.capture_message(error_message, extra: { backtrace: caller.join("\n") })
      fail!(error: error_message)
    end

    # Override in subclasses to extract the FDR error code from the response.
    # The error code will be included in the downstream error message.
    # Return nil to use the default error message without an error code.
    def extract_fdr_error_code(_response)
      nil
    end

    def failure_message
      msg = "FdrGateway call to #{action} failed"
      msg += " (fdr_error_code: #{@last_fdr_error_code})" if @last_fdr_error_code
      msg
    end

    def log_and_capture_error(message, response_body)
      error_message = "There was a problem with FdrGateway #{action}"

      Rails.logger.error(error_message)
      Rails.logger.error(response_body)

      Raven.capture_message(error_message,
                            fingerprint: ["{{ FdrGateway::#{action} }}"],
                            extra: { request_message: message, fdr_response_body: response_body })
    end

    def error_message(error_code)
      if error_code.nil?
        'Failed due to unknown issue'
      elsif (1000..1999).cover?(error_code.to_i)
        'Failed due to connection issue'
      elsif (2000..2999).cover?(error_code.to_i)
        'Failed due to missing data issue'
      elsif (10000..99999).cover?(error_code.to_i)
        'Failed due to data issue'
      end
    end

    def client
      @client ||= Savon.client(wsdl: wsdl_filepath,
                               endpoint: "#{fdr_host_path}/#{wsdl_namespace}/#{endpoint}",
                               ssl_verify_mode: :none, # see lib/README.txt for implementation notes
                               ssl_version: :TLSv1_2,
                               headers: { 'Host' => fdr_host, 'ClientName' => "cn=#{Certs.common_name}" },
                               env_namespace: :soapenv,
                               namespace_identifier: wsdl_namespace.to_sym,
                               soap_header: security_header,
                               raise_errors: false,
                               open_timeout: Env.savon_client_timeout,
                               read_timeout: Env.savon_client_timeout,
                               adapter: :net_http)
      # log: true,
      # log_level: :debug
    end

    def fdr_url_prefix
      Env.production? ? '' : 'cat-'
    end

    def mpls_url_prefix
      Env.mpls_enabled? ? 'pl-' : ''
    end

    def fdr_domain
      Env.mpls_enabled? ? 'aws.avant.creditcard' : 'fdcbusinessservices.com'
    end

    def fdr_host
      "#{fdr_url_prefix}#{mpls_url_prefix}#{wsdl_namespace}.#{fdr_domain}"
    end

    def fdr_host_path
      "https://#{fdr_host}"
    end

    def security_header
      result = FdrGateway::SecurityHeader.build(cert_file_content: Certs.cert_file_content,
                                                cert_key_file_content: Certs.key_file_content,
                                                wsdl_namespace: wsdl_namespace)

      result.security_header
    end

    def wsdl_filename
      namespace
    end

    def wsdl_namespace
      'fiws'
    end

    def wsdl_filepath
      Rails.root.join('lib', 'wsdl', namespace, "#{wsdl_filename}.wsdl")
    end

    def username
      Env.fdr_api_username
    end

    def object_to_array(object)
      if object.nil?
        []
      elsif object.is_a?(Hash)
        [object]
      elsif object.is_a?(Array)
        object
      else
        raise "Expected a Hash or Array, got #{object.class}. endpoint: #{endpoint}, object: #{object}"
      end
    end

    # We need this method because sometimes First Data returns looks like
    # an error but isn't actually.
    # Overridden in GetChronicleMemos, IssueLetter, SimpleNonmon, Accounts::Create,
    # CreditCards::Activate, CreditCards::Update, Customers::Update, Customers::UpdatePhoneNumber
    def response_considered_success?(response)
      response.success?
    end

    # Overridden in IssueLetter, SimpleNonmon, Accounts::Create, CreditCards::Activate,
    # CreditCards::Update, Customers::Update, Customers::UpdatePhoneNumber
    def response_status
      Constants.server_error
    end
  end
end
# rubocop:enable Metrics/ClassLength, Metrics/AbcSize
