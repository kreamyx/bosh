module Bosh::Director
    module DeploymentPlan
      module Stages
        class CreateNetworkStage
            def initialize(logger, deployment_plan)
                @logger = logger
                @deployment_plan = deployment_plan
            end
      
            def perform
                create_networks
            end

            private

            def managed_network?(network)
                network.managed
            end

            def reverse_parse_subnet(subnet)
                cpi_input = {}
                cpi_input['range'] = subnet.range.to_s if subnet.range
                cpi_input['cloud_properties'] = subnet.cloud_properties if subnet.cloud_properties
                cpi_input['gateway'] = subnet.gateway.ip if subnet.gateway
                cpi_input
            end

            def create_networks
                if Config.network_lifecycle_enabled?
                    @logger.info("Network lifecycle check")
                    @event_log_stage = Config.event_log.begin_stage('Creating managed networks')
                    @deployment_plan.networks.each do |network|
                        if managed_network?(network)
                            unless Bosh::Director::Models::Network.first(name: network.name)
                                @logger.info("Creating network: #{network.name}")
                                @event_log_stage.advance_and_track("#{network.name}") do                                  
                                    # update the network database tables
                                    nw = Bosh::Director::Models::Network.new(name: network.name, type: "manual", orphaned: false, created_at: Time.now)
                                    nw.save
                                    # call cpi to create network subnets
                                    network.subnets.each_with_index do |subnet, order|
                                        cloud_factory = AZCloudFactory.create_with_latest_configs(@deployment_plan.model)
                                        cpi = cloud_factory.get_for_az(subnet.availability_zone_names[0])
                                        network_create_results = cpi.create_subnet(reverse_parse_subnet(subnet))
                                        sn = Bosh::Director::Models::Subnet.new(cid: network_create_results["cid"], cloud_properties: JSON.dump(network_create_results["cloud_properties"]), order: order)
                                        nw.add_subnet(sn)
                                        sn.save
                                    end
                                end                
                            end             
                            # the network is in the database
                            db_network = Bosh::Director::Models::Network.first(name: network.name)
                            if db_network.orphaned
                                db_network.orphaned = false
                                db_network.save
                            end
                            # add relation between deployment and network
                            @deployment_plan.model.add_network(db_network)
                            network.subnets.each_with_index do |subnet, order|
                                db_subnet = db_network.subnets.find do |sn|
                                    sn.order == order
                                end
                                if db_subnet != nil
                                    subnet.cloud_properties = JSON.load(db_subnet.cloud_properties)
                                else
                                    # raise an error here
                                    # cant find a subnet with this name
                                    # this should never happen
                                end
                            end
                        end
                    end
                end
            end
        end
      end
    end
end