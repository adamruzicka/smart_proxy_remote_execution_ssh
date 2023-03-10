module Proxy::RemoteExecution::Script
  module Actions
    class PushScript < ::Dynflow::Action
# [{"proxy_operation_name"=>"ssh",
# "time_to_pickup"=>86400,
# "ssh_user"=>"root",
# "effective_user"=>"root",
# "effective_user_method"=>"sudo",
# "cleanup_working_dirs"=>false,
# "ssh_port"=>10022,
# "hostname"=>"127.0.0.1",
# "script"=>"ls -la /",
# "execution_timeout_interval"=>nil,
# "secrets"=>{"ssh_password"=>nil, "key_passphrase"=>nil, "effective_user_password"=>""},
# "use_batch_triggering"=>true,
# "use_concurrency_control"=>false,
# "first_execution"=>false,
# "alternative_names"=>{"fqdn"=>"aimee-schwenk.kerry-destree.example.org"},
# "connection_options"=>{"retry_interval"=>15, "retry_count"=>4, "proxy_batch_triggering"=>true},
# "proxy_url"=>"http://127.0.0.1:8000",
# "proxy_action_name"=>"Proxy::RemoteExecution::Ssh::Actions::RunScript",
# "current_request_id"=>"24cdeabc-2500-41c4-9251-51b81ec442c6",
# "current_timezone"=>"Europe/Prague",
# "current_organization_id"=>1,
# "current_location_id"=>2,
# "current_user_id"=>4,
# "callback"=>{"task_id"=>"e605ee53-4abd-40f0-8e33-ea1e3987c71d", "step_id"=>3},
# "callback_host"=>"http://127.0.0.1:8000"}]
      def plan(params)
        callback = params.delete('callback_path')
        params = self.class.convert_to_ssh_params(params)

        action = plan_action(::Proxy::RemoteExecution::Ssh::Actions::ScriptRunner, params)
        Proxy::RemoteExecution::Ssh.job_storage.create_mapping(execution_plan_id, action.id)
        plan_action(Callback::Action, callback, action.output) if callback
      end

      def self.convert_to_ssh_params(params)
        ssh = params.delete('ssh') || {}
        move_value(ssh, 'user', params, 'ssh_user')
        move_value(ssh, 'port', params, 'ssh_port')

        workdir = params.delete('working_directory') || {}
        move_value(workdir, 'local', params, 'local_working_dir')
        move_value(workdir, 'remote', params, 'remote_working_dir')
        move_value(workdir, 'cleanup', params, 'cleanup_working_dirs')

        effective = params.delete('effective_user') || {}
        move_value(effective, 'user', params, 'effective_user')
        move_value(effective, 'method', params, 'effective_user_method')

        params['secrets'] = {}
        secrets = params['secrets']
        move_value(ssh, 'password', secrets, 'ssh_password')
        move_value(ssh, 'key_passphrase', secrets, 'key_passphrase')
        move_value(effective, 'password', secrets, 'effective_user_password')

        params
      end

      def self.move_value(s_store, source, t_store, target)
        t_store[target] = s_store.delete(source) if s_store.key?(source)
      end
    end
  end
end
