module Proxy::RemoteExecution::Script
  module Actions
    module Callback
      class Request < ::Proxy::HttpRequest::ForemanRequest
        def callback(path, payload)
          request = request_factory.create_post path, payload
          response = send_request(request)

          if response.code.to_s != "200"
            raise "Failed performing callback to #{uri}: #{response.code} #{response.body}"
          end
          response
        end
      end

      class Action < ::Dynflow::Action
        def plan(callback, data)
          plan_self(:callback => callback, :data => data)
        end

        def run
          Callback::Request.new.callback(input[:callback], input[:data].to_json)
        ensure
          input.delete(:data)
        end
      end
    end
  end
end
