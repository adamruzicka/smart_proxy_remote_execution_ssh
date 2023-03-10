# lib/job_storage.rb
require 'sequel'

module Proxy::RemoteExecution::Ssh
  class JobStorage
    def initialize
      @db = Sequel.sqlite
      @db.create_table :jobs do
        DateTime :timestamp, null: false, default: Sequel::CURRENT_TIMESTAMP
        String :uuid, fixed: true, size: 36, primary_key: true, null: false
        String :hostname, null: false, index: true
        String :execution_plan_uuid, fixed: true, size: 36, null: false, index: true
        Integer :run_step_id, null: false
        String :effective_user
        String :job, text: true
      end

      @db.create_table :job_plan_mappings do
        String :job_uuid, fixed: true, size: 36, primary_key: true, null: false
        String :execution_plan_uuid, fixed: true, size: 36, null: false
        Integer :action_id, null: false
      end
    end

    def find_mapping(job_uuid)
      mappings.where(job_uuid: job_uuid).first
    end

    def create_mapping(plan_uuid, action_id, job_uuid: SecureRandom.uuid)
      mappings.insert(job_uuid, plan_uuid, action_id)
    end

    def find_mapping_by_plan(plan_uuid)
      mappings.where(execution_plan_uuid: plan_uuid).first
    end

    def is_mapping_available?(job_uuid)
      mappings.where(job_uuid: job_uuid).any?
    end

    def find_job(uuid, hostname)
      jobs.where(uuid: uuid, hostname: hostname).first
    end

    def job_uuids_for_host(hostname)
      jobs_for_host(hostname).order(:timestamp)
                             .select_map(:uuid)
    end

    def store_job(hostname, execution_plan_uuid, run_step_id, job, uuid: SecureRandom.uuid, timestamp: Time.now.utc, effective_user: nil)
      jobs.insert(timestamp: timestamp,
                  uuid: uuid,
                  hostname: hostname,
                  execution_plan_uuid: execution_plan_uuid,
                  run_step_id: run_step_id,
                  job: job,
                  effective_user: effective_user)
      uuid
    end

    def drop_job(execution_plan_uuid, run_step_id)
      jobs.where(execution_plan_uuid: execution_plan_uuid, run_step_id: run_step_id).delete
    end

    private

    def jobs_for_host(hostname)
      jobs.where(hostname: hostname)
    end

    def jobs
      @db[:jobs]
    end

    def mappings
      @db[:job_plan_mappings]
    end
  end
end
