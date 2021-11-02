# require 'net/ssh'
require 'smart_proxy_remote_execution_ssh/net_ssh_compat'
require 'forwardable'
require 'pry-remote'

module Proxy::RemoteExecution
  module Cockpit
    # A wrapper class around different kind of sockets to comply with Net::SSH event loop
    class BufferedSocket
      include Proxy::RemoteExecution::NetSSHCompat::BufferedIO
      extend Forwardable

      # The list of methods taken from OpenSSL::SSL::SocketForwarder for the object to act like a socket
      def_delegators(:@socket, :to_io, :addr, :peeraddr, :setsockopt,
                     :getsockopt, :fcntl, :close, :closed?, :do_not_reverse_lookup=)

      def initialize(socket)
        @socket = socket
        initialize_buffered_io
      end

      def recv
        raise NotImplementedError
      end

      def send
        raise NotImplementedError
      end

      def self.applies_for?(socket)
        raise NotImplementedError
      end

      def self.build(socket)
        klass = [OpenSSLBufferedSocket, MiniSSLBufferedSocket, StandardBufferedSocket].find do |potential_class|
          potential_class.applies_for?(socket)
        end
        raise "No suitable implementation of buffered socket available for #{socket.inspect}" unless klass
        klass.new(socket)
      end
    end

    class StandardBufferedSocket < BufferedSocket
      def_delegators(:@socket, :send, :recv)

      def self.applies_for?(socket)
        socket.respond_to?(:send) && socket.respond_to?(:recv)
      end
    end

    class OpenSSLBufferedSocket < BufferedSocket
      def self.applies_for?(socket)
        socket.is_a? ::OpenSSL::SSL::SSLSocket
      end
      def_delegators(:@socket, :read_nonblock, :write_nonblock, :close)

      def recv(n)
        res = ""
        begin
          # To drain a SSLSocket before we can go back to the event
          # loop, we need to repeatedly call read_nonblock; a single
          # call is not enough.
          loop do
            res += @socket.read_nonblock(n)
          end
        rescue IO::WaitReadable
          # Sometimes there is no payload after reading everything
          # from the underlying socket, but a empty string is treated
          # as EOF by Net::SSH. So we block a bit until we have
          # something to return.
          if res == ""
            IO.select([@socket.to_io])
            retry
          else
            res
          end
        rescue IO::WaitWritable
          # A renegotiation is happening, let it proceed.
          IO.select(nil, [@socket.to_io])
          retry
        end
      end

      def send(mesg, flags)
        @socket.write_nonblock(mesg)
      rescue IO::WaitWritable
        0
      rescue IO::WaitReadable
        IO.select([@socket.to_io])
        retry
      end
    end

    class MiniSSLBufferedSocket < BufferedSocket
      def self.applies_for?(socket)
        socket.is_a? ::Puma::MiniSSL::Socket
      end
      def_delegators(:@socket, :read_nonblock, :write_nonblock, :close)

      def recv(n)
        @socket.read_nonblock(n)
      end

      def send(mesg, flags)
        @socket.write_nonblock(mesg)
      end

      def closed?
        @socket.to_io.closed?
      end
    end

    class Session
      include ::Proxy::Log

      def initialize(env)
        @env = env
      end

      def valid?
        @env["HTTP_CONNECTION"] == "upgrade" && @env["HTTP_UPGRADE"].to_s.split(',').any? { |part| part.strip == "raw" }
      end

      def hijack!
        @socket = nil
        if @env['ext.hijack!']
          @socket = @env['ext.hijack!'].call
        elsif @env['rack.hijack?']
          begin
            @env['rack.hijack'].call
          rescue NotImplementedError
          end
          @socket = @env['rack.hijack_io']
        end
        raise 'Internal error: request hijacking not available' unless @socket
        ssh_on_socket
      end

      private

      def ssh_on_socket
        with_error_handling { system_ssh_loop }
      end

      def with_error_handling
        yield
      # TODO
      # rescue Net::SSH::AuthenticationFailed => e
      #   send_error(401, e.message)
      # rescue Errno::EHOSTUNREACH
      #   send_error(400, "No route to #{host}")
      # rescue SystemCallError => e
      #   send_error(400, e.message)
      # rescue SocketError => e
      #   send_error(400, e.message)
      rescue Exception => e
        logger.error e.message
        logger.debug e.backtrace.join("\n")
        send_error(500, "Internal error") unless @started
      ensure
        unless buf_socket.closed?
          buf_socket.wait_for_pending_sends
          buf_socket.close
        end
      end

      def system_ssh_loop
        in_read, in_write   = IO.pipe
        out_read, out_write = IO.pipe
        err_read, err_write = IO.pipe

        args = []
        # TODO
        # args += [{'SSHPASS' => @ssh_password}, '/usr/bin/sshpass', '-e'] if @ssh_password
        ssh_options = [
          "-o User=#{ssh_user}",
          '-i', key_file
        ]
        args += ['/usr/bin/ssh', host, ssh_options, command].flatten
        pid = spawn(*args, :in => in_read, :out => out_write, :err => err_write)
        [in_read, out_write, err_write].each(&:close)

        send_start
        err_buf_raw = ''
        # Not SSL buffer, but the interface kinda matches
        out_buf = MiniSSLBufferedSocket.new(out_read)
        err_buf = MiniSSLBufferedSocket.new(err_read)
        in_buf  = MiniSSLBufferedSocket.new(in_write)

        readers = [buf_socket, out_buf, err_buf]

        loop do
          # Prime the sockets for reading
          ready_readers, ready_writers = IO.select(readers, [buf_socket, in_buf], nil, 300)
          (ready_readers || []) .each { |reader| reader.close if reader.fill.zero? }

          { out_buf => buf_socket, buf_socket => in_buf }.each do |src, dst|
            dst.enqueue(src.read_available) if src.available.positive?
            dst.close if src.closed?
          end

          if out_buf.closed?
            code = Process.wait2(pid).last.exitstatus
            send_start if code.zero? # TODO: Why?
            err_buf_raw += "Process exited with code #{code}.\r\n"
            break
          end

          if err_buf.available.positive?
            err_buf_raw += sock.read_nonblock(err_buf.read_available)
          end

          (ready_writers || []).each { |writer| writer.respond_to?(:send_pending) ? writer.send_pending : writer.flush }
        end
      rescue => e
        send_error(400, err_buf_raw) unless @started
      end

      # TODO: Remove
      def start_ssh_loop
        err_buf = ""

        Net::SSH.start(host, ssh_user, ssh_options) do |ssh|
          channel = ssh.open_channel do |ch|
            ch.exec(command) do |ch, success|
              raise "could not execute command" unless success

              ssh.listen_to(buf_socket)

              ch.on_process do
                if buf_socket.available.positive?
                  ch.send_data(buf_socket.read_available)
                end
                if buf_socket.closed?
                  ch.close
                end
              end

              ch.on_data do |ch2, data|
                send_start
                buf_socket.enqueue(data)
              end

              ch.on_request('exit-status') do |ch, data|
                code = data.read_long
                send_start if code.zero?
                err_buf += "Process exited with code #{code}.\r\n"
                ch.close
              end

              ch.on_request('exit-signal') do |ch, data|
                err_buf += "Process was terminated with signal #{data.read_string}.\r\n"
                ch.close
              end

              ch.on_extended_data do |ch2, type, data|
                err_buf += data
              end
            end
          end

          channel.wait
          send_error(400, err_buf) unless @started
        end
      end

      def send_start
        unless @started
          @started = true
          buf_socket.enqueue("Status: 101\r\n")
          buf_socket.enqueue("Connection: upgrade\r\n")
          buf_socket.enqueue("Upgrade: raw\r\n")
          buf_socket.enqueue("\r\n")
          buf_socket.send_pending
        end
      end

      def send_error(code, msg)
        buf_socket.enqueue("Status: #{code}\r\n")
        buf_socket.enqueue("Connection: close\r\n")
        buf_socket.enqueue("\r\n")
        buf_socket.enqueue(msg)
        buf_socket.send_pending
      end

      def params
        @params ||= MultiJson.load(@env["rack.input"].read)
      end

      def key_file
        @key_file ||= Proxy::RemoteExecution::Ssh.private_key_file
      end

      def buf_socket
        @buffered_socket ||= BufferedSocket.build(@socket)
      end

      def command
        params["command"]
      end

      def ssh_user
        params["ssh_user"]
      end

      def host
        params["hostname"]
      end

      # TODO: Map to ssh options
      def ssh_options
        auth_methods = %w[publickey]
        auth_methods.unshift('password') if params["ssh_password"]

        ret = {}
        ret[:port] = params["ssh_port"] if params["ssh_port"]
        ret[:keys] = [key_file] if key_file
        ret[:password] = params["ssh_password"] if params["ssh_password"]
        ret[:passphrase] = params["ssh_key_passphrase"] if params["ssh_key_passphrase"]
        ret[:keys_only] = true
        ret[:auth_methods] = auth_methods
        ret[:verify_host_key] = true
        ret[:number_of_password_prompts] = 1
        ret
      end
    end
  end
end
