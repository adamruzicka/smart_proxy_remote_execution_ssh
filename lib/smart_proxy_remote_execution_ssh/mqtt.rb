require 'connection_pool'
require 'mqtt'

require 'smart_proxy_remote_execution_ssh/mqtt/handler'

module Proxy::RemoteExecution::Ssh
  class MQTT
    class << self
      def connection_pool
        @mqtt_connection_pool ||= ::ConnectionPool.new(size: 5) do
          client = self.new
          client.connect_in_thread!
          client
        end
      end

      def with_pooled_connection(&block)
        connection_pool.with do |mqtt|
          mqtt.connect_in_thread! unless mqtt.client.connected?
          yield mqtt.client
        end
      end
    end

    attr_reader :client
    def initialize
      @client = ::MQTT::Client.new
      @client.host = ::Proxy::RemoteExecution::Ssh::Plugin.settings.mqtt_broker
      @client.port = ::Proxy::RemoteExecution::Ssh::Plugin.settings.mqtt_port
      @client.ssl = ::Proxy::RemoteExecution::Ssh::Plugin.settings.mqtt_tls
      @client.cert_file = ::Proxy::SETTINGS.foreman_ssl_cert || ::Proxy::SETTINGS.ssl_certificate
      @client.key_file = ::Proxy::SETTINGS.foreman_ssl_key || ::Proxy::SETTINGS.ssl_private_key
      @client.ca_file = ::Proxy::SETTINGS.foreman_ssl_ca || ::Proxy::SETTINGS.ssl_ca_file
    end

    def with_connection(&block)
      @client.connect(&block)
    end

    def close
      @client.disconnect if @client.connected?
    end

    # ruby-mqtt does some non-standard things when it comes to threads and
    # exception handling. Once a connection is established, it creates a new
    # thread which reads data from the connection. This newly spawned thread
    # holds a reference to the thread that spawned it. If this reader thread
    # encounters an exception, it re-raises it in its parent thread.
    #
    # This poses an issue if the connections are pooled and workers on a thread
    # pool borrow the connections from the pool. Usually a worker borrows a
    # client from the pool, establishes the connection and returns the client
    # when done. However the reading thread keeps a reference to the worker's
    # thread and can raise an exception in there.
    #
    # This is an ugly workaround, the connection is established in a thread that
    # is joined just after establishing the connection, meaning the reader
    # thread may raise an exception on a dead thread which passes silently.
    def connect_in_thread!
      return if @client.connected?

      # Cleanup in case the connection got broken
      @client.disconnect
      Thread.new { @client.connect }.join
    end
  end
end
