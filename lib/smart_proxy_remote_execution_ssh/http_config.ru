map "/ssh" do
  run Proxy::RemoteExecution::Ssh::Api
end

map "/remote_execution/ssh" do
  run Proxy::RemoteExecution::Ssh::Api
end

map "/remote_execution/script" do
  run Proxy::RemoteExecution::Script::Api
end
