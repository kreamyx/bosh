module Bosh
  module Director
    module DeploymentPlan
      module PlacementPlanner
        class Plan
          def initialize(instance_plan_factory, network_planner, logger)
            @instance_plan_factory = instance_plan_factory
            @network_planner = network_planner
            @logger = logger
          end

          # placement planner is PER instance group

          # job_name is actually the instace group job_name
          # desired = desired instances
          # existing = existing_instance_models
          # networks = non-vip networks defined in the instance group
          # availability zones are those defined in the instance groups

          # Returns: an array of instance plans
          def create_instance_plans(desired, existing, networks, availability_zones, job_name)
            sorted_existing = existing.sort_by(&:index)
            # Karim: returns an array of an instance plan per instance 
            instance_plans = assign_zones(desired, sorted_existing, networks, availability_zones, job_name)

            instance_plans.reject(&:obsolete?).each do |instance_plan|
              @logger.debug("Assigning az '#{instance_plan.desired_instance.availability_zone}' to instance '#{instance_plan.instance}'")
              instance_plan.instance.assign_availability_zone_and_update_cloud_properties(instance_plan.desired_instance.az, instance_plan.desired_instance.instance_group.vm_type, instance_plan.desired_instance.instance_group.vm_extensions)
            end
            instance_plans
          end

          private

          # Karim: assigning the placement of an instance group is either based on static ips or based on persistent disk allocation
          def assign_zones(desired, existing, networks, availability_zones, job_name)
            if has_static_ips?(networks)
              @logger.debug("Job '#{job_name}' has networks with static IPs, placing instances based on static IP distribution")
              StaticIpsAvailabilityZonePicker.new(@instance_plan_factory, @network_planner, networks, job_name, availability_zones, @logger).place_and_match_in(desired, existing)
            else
              @logger.debug("Job '#{job_name}' does not have networks with static IPs, placing instances based on persistent disk allocation")
              AvailabilityZonePicker.new(@instance_plan_factory, @network_planner, networks, availability_zones).place_and_match_in(desired, existing)
            end
          end

          def has_static_ips?(networks)
            # return true if any of the networks supplied has static ips
            !networks.nil? && networks.any? { |network| !! network.static_ips }
          end
        end
      end
    end
  end
end
