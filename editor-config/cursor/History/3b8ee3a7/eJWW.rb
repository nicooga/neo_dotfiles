require_dependency "root_api"
require_dependency "not_found_api"
require_dependency "sidekiq-ent/web"
require_dependency "sidekiq-status/web"
require_dependency "contextual_messaging/api"

Rails.application.routes.draw do
  # For details on the DSL available within this file, see http://guides.rubyonrails.org/routing.html

  # Mount Contextual Messaging API at /cm
  mount ContextualMessaging::Api => "/cm"

  mount FdrGateway::Api::RootApi => "/"

  mount GrapeSwaggerRails::Engine => '/swagger' if ENV['SWAGGER_URL'] || Rails.env.development?

  mount Sidekiq::Web => '/sidekiq'

  # Catches all undefined routes instead of simply raising an ActionController::RoutingError
  # It has to be at the VERY end of all routes because it catches everything
  mount FdrGateway::Api::NotFoundApi => '/'

end
