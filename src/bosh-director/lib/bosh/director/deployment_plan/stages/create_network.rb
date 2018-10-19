module Bosh::Director
  module DeploymentPlan
    module Stages
      class CreateNetworkStage
        include LockHelper
        include IpUtil

        def initialize(logger, deployment_plan)
          @logger = logger
          @deployment_plan = deployment_plan
        end

        def perform
          create_networks
        end

        private

        def network_update_plan(network_name, network_subnets, subnet_models, deployment_cloud_config)
          old_network = deployment_cloud_config['networks'].find { |x| x['name'] == network_name }
          old_subnets = old_network['subnets']

          subnets_to_add = network_subnets.select do |subnet|
            subnet_models.find { |e| e.name == subnet.name }.nil?
          end

          subnets_to_remove = subnet_models.select do |subnet|
            network_subnets.find { |e| e.name == subnet.name }.nil?
          end

          # exclude all subnets that only had name changes
          subnets_to_remove.delete_if do |subnet_model|
            old_subnet = old_subnets.find { |x| x['name'] == subnet_model.name }
            # old_subnet will be nil only when a subnet has been modified. A new database entry will be created
            # TODO: refactor this part
            next if old_subnet.nil?
            next unless old_subnet.key?('range')

            old_range = NetAddr::CIDR.create(old_subnet['range'])
            old_gateway = NetAddr::CIDR.create(old_subnet['gateway'])
            s = subnets_to_add.find do |new_subnet|
              new_subnet.range == old_range && \
                new_subnet.gateway == old_gateway && \
                new_subnet.cloud_properties == old_subnet['cloud_properties']
            end

            if s.nil?
              false
            else
              subnet_model.name = s.name
              # TODO: Also modify the reserved field if necessary
              subnet_model.save
              subnets_to_add.delete_if { |subnet| subnet.name == s.name }
              true
            end
          end

          [subnets_to_add, subnets_to_remove]
        end

        def get_modified_subnets(network_name, latest_cloud_config, deployment_cloud_config)
          latest_network = latest_cloud_config['networks'].find { |x| x['name'] == network_name }
          latest_subnets = latest_network['subnets']

          old_network = deployment_cloud_config['networks'].find { |x| x['name'] == network_name }
          return [] if old_network.nil?

          old_subnets = old_network['subnets']
          recreate_subnets = []
          no_recreate_subnets = []

          common_subnets = latest_subnets.map { |x| x['name'] } & old_subnets.map { |x| x['name'] }
          common_subnets.each do |subnet_name|
            new_subnet = latest_subnets.find { |x| x['name'] == subnet_name }
            old_subnet = old_subnets.find { |x| x['name'] == subnet_name }
            next if new_subnet == old_subnet
            if new_subnet['range'] != old_subnet['range'] ||
               new_subnet['gateway'] != old_subnet['gateway'] ||
               new_subnet['netmask_bits'] != old_subnet['netmask_bits'] ||
               new_subnet['cloud_properties'] != old_subnet['cloud_properties'] ||
               new_subnet['azs'] != old_subnet['azs']

              recreate_subnets << subnet_name
            else
              no_recreate_subnets << subnet_name
            end
          end

          # recreate_subnets are modified subnets that will require the recreation of the network
          # no_recreate_subnet are modified subnets that only require a change in the database
          [recreate_subnets, no_recreate_subnets]
        end

        def create_networks
          return unless Config.network_lifecycle_enabled?

          @logger.info('Network lifecycle check')
          @event_log_stage = Config.event_log.begin_stage('Creating managed networks')

          @deployment_plan.instance_groups.each do |inst_group|
            inst_group.networks.each do |jobnetwork|
              network = jobnetwork.deployment_network
              latest_cloud_config = Bosh::Director::Api::CloudConfigManager.new.list(1).first.raw_manifest
              deployment_cloud_config = @deployment_plan.model.cloud_configs.sort(&:id).last.raw_manifest
              old_network = deployment_cloud_config['networks'].find { |x| x['name'] == network.name }

              unless network.managed? || old_network.nil?
                previously_managed = old_network.fetch('managed', false)
                if previously_managed
                  db_network = Bosh::Director::Models::Network.first(name: network.name)
                  db_network.destroy unless db_network.nil?
                end
                next
              end

              with_network_lock(network.name) do
                db_network = Bosh::Director::Models::Network.first(name: network.name)
                # TODO: here you need to compare the information you get from db with the cloud config info
                # may be sth like an update plan (comparison between current state and cloud config state)
                if db_network.nil?
                  db_network = create_network(network)
                else
                  # this could be a case of network update
                  recreate_subnets, no_recreate_subnets = get_modified_subnets(
                    network.name,
                    latest_cloud_config,
                    deployment_cloud_config,
                  )
                  unless recreate_subnets.empty? && no_recreate_subnets.empty?
                    recreate_subnets.each do |subnet_name|
                      db_subnet = db_network.subnets.find { |sn| sn.name == subnet_name }
                      db_subnet.name = "#{subnet_name}_outdated_#{SecureRandom.uuid}"
                      db_subnet.save
                    end
                    no_recreate_subnets.each do |subnet_name|
                      # db_subnet = db_network.subnets.find { |sn| sn.name == subnet_name }
                      # latest_network = latest_cloud_config['networks'].find {|x| x['name'] == network_name}
                      # new_subnet = latest_network['subnets'].find{|x| x['name'] == subnet_name}
                      # TODO: Change reserved in the database
                    end
                  end

                  subnets_to_add, subnets_to_remove = network_update_plan(
                    network.name,
                    network.subnets,
                    db_network.subnets,
                    deployment_cloud_config,
                  )

                  subnets_to_add.each do |subnet|
                    subnets_to_remove.each do |to_remove_subnet|
                      next unless subnet.range
                      old_range = NetAddr::CIDR.create(to_remove_subnet.range)
                      if old_range == subnet.range ||
                         old_range.contains?(subnet.range) ||
                         subnet.range.contains?(old_range)

                        raise NetworkOverlappingSubnets, "Subnet '#{subnet.name}' in managed network '#{network.name}' cannot be modified to an overlapping subnet" if to_remove_subnet.name.start_with?(subnet.name)

                        raise NetworkOverlappingSubnets, "Updating managed network '#{network.name}' doesnot support overlapping subnets. Subnet '#{subnet.name}' overlaps with subnet '#{to_remove_subnet.name}'"
                      end
                    end
                    # should be behind begin and rescue
                    create_subnet(subnet, db_network, {})
                  end
                end

                if db_network.orphaned
                  db_network.orphaned = false
                  db_network.save
                end

                # add relation between deployment and network
                @deployment_plan.model.add_network(db_network) unless @deployment_plan.model.networks.include?(db_network)

                # fetch the subnet cloud properties from the database
                network.subnets.each do |subnet|
                  db_subnet = db_network.subnets.find { |sn| sn.name == subnet.name }
                  raise Bosh::Director::SubnetNotFoundInDB, "cannot find subnet: #{subnet.name} in the database" if db_subnet.nil?
                  populate_subnet_properties(subnet, db_subnet)
                end
              end
            end
          end
        end

        def create_network(network)
          validate_subnets(network)

          @logger.info("Creating network: #{network.name}")

          created_network = nil

          @event_log_stage.advance_and_track(network.name.to_s) do
            created_network = Bosh::Director::Models::Network.create(
              name: network.name,
              type: 'manual',
              orphaned: false,
              created_at: Time.now,
            )

            begin
              rollback = {}

              network.subnets.each do |subnet|
                create_subnet(subnet, created_network, rollback)
              end
            rescue StandardError => e
              rollback.each do |cid, cpi|
                begin
                  @logger.info("deleting subnet #{cid}")
                  cpi.delete_network(cid)
                rescue StandardError => e
                  @logger.info("failed to delete subnet #{cid}: #{e.message}")
                end
              end

              @logger.info("deleting network #{created_network.name}")
              created_network.destroy

              raise "deployment failed during creating managed networks: #{e.message}"
            end
          end

          created_network
        end

        def validate_subnets(network)
          names = {}
          network.subnets.each do |subnet|
            raise 'subnet in managed network must have a name' if subnet.name.nil?
            raise 'subnet names within a managed network must be unique' if names.key?(subnet.name)
            names[subnet.name] = true
          end
        end

        def create_subnet(subnet, network_model, rollback)
          cloud_factory = AZCloudFactory.create_with_latest_configs(@deployment_plan.model)
          cpi_name = ''
          az_cloud_properties = {}

          if !subnet.availability_zone_names.nil? && subnet.availability_zone_names.count != 0
            cpi_name = cloud_factory.get_name_for_az(subnet.availability_zone_names.first)
            subnet.availability_zone_names.each do |az_name|
              availability_zone = @deployment_plan.availability_zones.find { |az| az.name == az_name }
              az_cloud_properties.merge!(availability_zone.cloud_properties)
            end
          end

          cpi = cloud_factory.get(cpi_name)
          network_create_results = cpi.create_network(fetch_cpi_input(subnet, az_cloud_properties))
          network_cid = network_create_results[0]
          network_address_properties = network_create_results[1]
          network_cloud_properties = network_create_results[2]

          range = subnet.range ? subnet.range.to_s : network_address_properties['range']
          gw = subnet.gateway ? subnet.gateway.ip : network_address_properties['gateway']

          reserved_ips = network_address_properties.fetch('reserved', [])
          rollback[network_cid] = cpi
          sn = Bosh::Director::Models::Subnet.new(
            cid: network_cid,
            cloud_properties: JSON.dump(network_cloud_properties),
            name: subnet.name,
            range: range,
            gateway: gw,
            reserved: JSON.dump(reserved_ips),
            cpi: cpi_name,
          )
          network_model.add_subnet(sn)
          sn.save
        end

        def fetch_cpi_input(subnet, az_cloud_props)
          az_cloud_props ||= {}
          cpi_input = {
            'type': 'manual',
            'cloud_properties': {},
          }
          cpi_input['cloud_properties'] = az_cloud_props.merge(subnet.cloud_properties) if subnet.cloud_properties
          cpi_input['range'] = subnet.range.to_s if subnet.range
          cpi_input['gateway'] = subnet.gateway.ip if subnet.gateway
          cpi_input['netmask_bits'] = subnet.netmask_bits if subnet.netmask_bits
          cpi_input
        end

        def populate_subnet_properties(subnet, db_subnet)
          subnet.cloud_properties = JSON.parse(db_subnet.cloud_properties)
          subnet.range = NetAddr::CIDR.create(db_subnet.range)
          subnet.gateway = NetAddr::CIDR.create(db_subnet.gateway)
          subnet.netmask = subnet.range.wildcard_mask
          network_id = subnet.range.network(Objectify: true)
          broadcast = subnet.range.version == 6 ? subnet.range.last(Objectify: true) : subnet.range.broadcast(Objectify: true)
          subnet.restricted_ips.add(subnet.gateway.to_i) if subnet.gateway
          subnet.restricted_ips.add(network_id.to_i)
          subnet.restricted_ips.add(broadcast.to_i)
          each_ip(JSON.parse(db_subnet.reserved)) do |ip|
            unless subnet.range.contains?(ip)
              raise NetworkReservedIpOutOfRange,
                    "Reserved IP '#{format_ip(ip)}' is out of " \
                    "subnet '#{subnet.name}' range"
            end
            subnet.restricted_ips.add(ip)
          end
        end
      end
    end
  end
end
