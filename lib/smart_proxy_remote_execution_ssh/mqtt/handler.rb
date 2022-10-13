require 'json'

module Proxy::RemoteExecution::Ssh
  class MQTT
    class Handler
      class << self

        def start_thread!
          @thread ||= Thread.new do
            handler = Handler.new
            handler.with_retries { handler.dispatch_loop }
          end
        end
      end

      def initialize
        @conn = MQTT.new
      end

      def with_retries
        yield
      rescue Exception => e
        logger.exception("MQTT dispatch thread encountered exception, retrying in 15 seconds", e)
        @conn.close
				sleep 15
        retry
      end

      def dispatch_loop
        @conn.with_connection do |c|
          c.subscribe('yggdrasil/+/control/out' => 1)
          c.get { |topic, message| handle_message(topic, message) }
        end
      end

      def handle_message(topic, message)
        host_id = %r{yggdrasil/([^/])+/control/out}.match(topic)[1]

        data = JSON.parse(message)
        case data['type']
        when 'connection-status'
          handle_connection_status(host_id, data)
        end
      end

      def handle_connection_status(host_id, data)
        if data.fetch('content', {})['state'] == 'online'
          ::Proxy::RemoteExecution::Ssh.job_storage.jobs_for_host(host_id).each do |job|
						payload = {
							type: 'data',
							message_id: SecureRandom.uuid,
							version: 1,
							sent: DateTime.now.iso8601,
							directive: 'foreman',
							content: "#{job[:proxy_url]}/ssh/jobs/#{job[:uuid]}",
							metadata: {
								'event': 'start',
								'job_uuid': job[:uuid],
								'return_url': "#{job[:proxy_url]}/ssh/jobs/#{job[:uuid]}/update",
							},
						}

            @conn.client.publish("yggdrasil/#{host_id}/data/in", JSON.dump(payload), false, 1)
          end
        end
      end

      def logger
        Proxy::RemoteExecution::Ssh::Plugin.logger
      end
    end
  end
end
