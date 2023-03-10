require 'multi_json'

module Proxy::RemoteExecution
  module Script
    class Api < ::Sinatra::Base
      include Sinatra::Authorization::Helpers
      include Proxy::Dynflow::Helpers

      # get '/jobs' do
      # end

      post '/jobs' do
        # Ones marked with * are required

        # type* - one of ssh, ssh-async, pull, pull-mqtt
        #
        # hostname*
        # alternative_names:
        #   consumer_uuid
        #   fqdn
        # script*
        #
        # effective_user:
        #   user
        #   method
        #   password
        #
        # ssh:
        #   port
        #   user
        #   host_public_key
        #   first_execution
        #   password
        #   key_passphrase
        #
        # working_directories:
        #   cleanup
        #   local
        #   remote
        #
        # execution_timeout_interval
        #
        # pull:
        #   time_to_pickup
        #
        # callback_path
        params = MultiJson.load(request.body.read)
        params['type'] ||= ::Proxy::RemoteExecution::Ssh::Plugin.settings.mode.to_s
        action_class = case params['type']
                       when 'ssh', 'ssh-async'
                         ::Proxy::RemoteExecution::Script::Actions::PushScript
                       when 'pull', 'pull-mqtt'
                         ::Proxy::RemoteExecution::Script::Actions::PullScript
                       else
                         halt 422, {'Content-Type' => 'application/json'}, { error: "Requested unknown type '#{params['type']}'" }.to_json
                         return
                       end

        plan = world.trigger(action_class, params)
        mapping = job_storage.find_mapping_by_plan(plan.id)
        { id: mapping[:job_uuid] }.to_json
      end

      # post '/jobs/:id' do |id|
      # end

      # post '/jobs/:id/cancel' do |id|
      # end

      get '/jobs/:id' do |id|
        job = job_storage.find_mapping(id)
        halt 404 unless job

        plan = world.persistence.load_execution_plan(job[:execution_plan_uuid])
        action = world.persistence.load_action_for_presentation(plan, job[:action_id])
        { job_uuid: id, status: plan.state, result: plan.result, output: action.format_output }.to_json
      end

      # post '/bulk' do
      #   # same as POST /jobs, except for hostname and alternative_names
      #   # inventory:
      #   #   hostname:
      #   #     per-host overrides, same as POST /jobs
      # end

      # get '/bulk' do
      # end
      private

      def job_storage
        Proxy::RemoteExecution::Ssh.job_storage
      end
    end
  end
end
