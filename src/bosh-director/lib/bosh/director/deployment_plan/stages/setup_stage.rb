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

        # def create_network
        #   @logger.info('Creating missing Networks')
        #   nw_model = Models::Network.new
        #   # what is the network name?
        #   nw_model.name = @deployment_plan.networks[0].name
        #   nw_model.save
        #   # add the network to the deployment
        #   nw_model.add_deployment(@deployment_plan.model)
        # end

        def persist_dns_az_encodings
          azs = @deployment_plan.availability_zones.map(&:name)
          LocalDnsEncoderManager.persist_az_names(azs)
        end

        def create_vms
          @logger.info('Creating missing VMs')

          missing_plans = @deployment_plan.instance_plans_with_missing_vms
          hotswap_plans = @deployment_plan.instance_plans_with_hot_swap_and_needs_shutdown

          @vm_creator.create_for_instance_plans(
            missing_plans + hotswap_plans,
            @deployment_plan.ip_provider,
            @deployment_plan.tags
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
