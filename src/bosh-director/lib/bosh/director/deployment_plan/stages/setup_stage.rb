module Bosh::Director
  module DeploymentPlan
    module Stages
      class SetupStage
        def initialize(base_job, deployment_plan, vm_creator, local_dns_repo, dns_publisher)
          @base_job = base_job
          @logger = base_job.logger
          @deployment_plan = deployment_plan
          @vm_creator = vm_creator
          @local_dns_repo = local_dns_repo
          @dns_publisher = dns_publisher
        end

        def perform
          persist_dns_az_encodings
          create_vms
        end

        private

        def persist_dns_az_encodings
          azs = @deployment_plan.availability_zones.map(&:name)
          LocalDnsEncoderManager.persist_az_names(azs)
        end

        def create_vms
          @logger.info('Creating missing VMs')

          missing_plans = @deployment_plan.instance_plans_with_missing_vms
          create_swap_delete_plans = @deployment_plan.instance_plans_with_create_swap_delete_and_needs_duplicate_vm

          @deployment_plan.skipped_instance_plans_with_create_swap_delete_and_needs_duplicate_vm.each do |instance_plan|
            @logger.info("Skipping create-swap-delete for static ip enabled instance #{instance_plan.instance_model}")
          end

          @vm_creator.create_for_instance_plans(
            missing_plans + create_swap_delete_plans,
            @deployment_plan.ip_provider,
            @deployment_plan.tags,
          )

          missing_plans.each do |plan|
            @local_dns_repo.update_for_instance(plan.instance.model)
          end
          @dns_publisher.publish_and_broadcast

          @base_job.task_checkpoint
        end
      end
    end
  end
end
