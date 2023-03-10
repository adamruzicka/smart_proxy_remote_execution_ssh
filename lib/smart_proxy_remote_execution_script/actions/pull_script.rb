module Proxy::RemoteExecution::Script
  module Actions
    class PullScript < ::Dynflow::Action
      def plan(params)
        pull = params.delete('pull') || {}
        params['time_to_pickup'] = pull.delete('time_to_pickup') if pull.key?('time_to_pickup')

        action = plan_action(::Proxy::RemoteExecution::Ssh::Actions::PullScript, params, true)
        Proxy::RemoteExecution::Ssh.job_storage.create_mapping(execution_plan_id, action.id)

        callback = params['callback_path']
        plan_action(Callback::Action, callback, action.output) if callback
      end
    end
  end
end
