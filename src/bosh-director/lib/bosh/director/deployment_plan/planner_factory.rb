require 'bosh/director/deployment_plan/deployment_spec_parser'
require 'bosh/director/deployment_plan/cloud_manifest_parser'

module Bosh
  module Director
    module DeploymentPlan
      class TransientDeployment
        def initialize(name, manifest, release_versions)
          @name = name
          @manifest = manifest
          @release_versions = release_versions
          @vms = []
        end
        attr_accessor :name, :manifest, :release_versions, :vms
      end

      class PlannerFactory
        include ValidationHelper

        def self.create(logger)
          deployment_manifest_migrator = Bosh::Director::DeploymentPlan::ManifestMigrator.new
          manifest_validator = Bosh::Director::DeploymentPlan::ManifestValidator.new
          deployment_repo = Bosh::Director::DeploymentPlan::DeploymentRepo.new

          new(
            deployment_manifest_migrator,
            manifest_validator,
            deployment_repo,
            logger
          )
        end

        def initialize(deployment_manifest_migrator, manifest_validator, deployment_repo, logger)
          @deployment_manifest_migrator = deployment_manifest_migrator
          @manifest_validator = manifest_validator
          @deployment_repo = deployment_repo
          @logger = logger
        end

        def create_from_model(deployment_model, options = {})
          manifest = Manifest.load_from_model(deployment_model)
          create_from_manifest(manifest, deployment_model.cloud_configs, deployment_model.runtime_configs, options)
        end

        def create_from_manifest(manifest, cloud_configs, runtime_configs, options)
          consolidated_runtime_config = Bosh::Director::RuntimeConfig::RuntimeConfigsConsolidator.new(runtime_configs)
          consolidated_cloud_config = Bosh::Director::CloudConfig::CloudConfigsConsolidator.new(cloud_configs)
          parse_from_manifest(manifest, consolidated_cloud_config, consolidated_runtime_config, options)
        end

        private

        def parse_from_manifest(manifest, cloud_config_consolidator, runtime_config_consolidator, options)
          # KE: this function is called once during a deployment
          @manifest_validator.validate(manifest.manifest_hash, manifest.cloud_config_hash)

          migrated_manifest_object, cloud_manifest = @deployment_manifest_migrator.migrate(manifest, manifest.cloud_config_hash)
          manifest.resolve_aliases
          migrated_manifest_hash = migrated_manifest_object.manifest_hash
          @logger.debug("Migrated deployment manifest:\n#{migrated_manifest_object.manifest_hash}")
          @logger.debug("Migrated cloud config manifest:\n#{cloud_manifest}")
          name = migrated_manifest_hash['name']

          deployment_model = @deployment_repo.find_or_create_by_name(name, options)
          deployment_model.add_variable_set(created_at: Time.now, writable: true) if deployment_model.variable_sets.empty?

          attrs = {
            name: name,
            properties: migrated_manifest_hash.fetch('properties', {})
          }

          plan_options = {
            'is_deploy_action' => !!options['deploy'],
            'recreate' => !!options['recreate'],
            'fix' => !!options['fix'],
            'skip_drain' => options['skip_drain'],
            'job_states' => options['job_states'] || {},
            'max_in_flight' => validate_and_get_argument(options['max_in_flight'], 'max_in_flight'),
            'canaries' => validate_and_get_argument(options['canaries'], 'canaries'),
            'tags' => parse_tags(migrated_manifest_hash, runtime_config_consolidator)
          }

          @logger.info('Creating deployment plan')
          @logger.info("Deployment plan options: #{plan_options}")


          # deployment here is a planner object
          deployment = Planner.new(attrs, migrated_manifest_object.manifest_hash, migrated_manifest_object.manifest_text, cloud_config_consolidator.cloud_configs, runtime_config_consolidator.runtime_configs, deployment_model, plan_options)

          # create the cloud planner and add it to the planner object "deployment"
          global_network_resolver = GlobalNetworkResolver.new(deployment, Config.director_ips, @logger)
          ip_provider_factory = IpProviderFactory.new(deployment.using_global_networking?, @logger)
          deployment.cloud_planner = CloudManifestParser.new(@logger).parse(cloud_manifest, global_network_resolver, ip_provider_factory)

          

          # this is where the instance groups and stuff are added to the planner
          # very important. parse is called.
          # this literally just parses the manifest and modify the deployment "planner" object
          DeploymentSpecParser.new(deployment, Config.event_log, @logger).parse(migrated_manifest_hash, plan_options)

          unless deployment.addons.empty?
            deployment.addons.each do |addon|
              addon.add_to_deployment(deployment)
            end
          end

          if runtime_config_consolidator.have_runtime_configs?
            parsed_runtime_config = RuntimeConfig::RuntimeManifestParser.new(@logger).parse(runtime_config_consolidator.interpolate_manifest_for_deployment(name))

            parsed_runtime_config.get_applicable_releases(deployment).each do |release|
              release.add_to_deployment(deployment)
            end
            parsed_runtime_config.addons.each do |addon|
              addon.add_to_deployment(deployment)
            end
            deployment.add_variables(parsed_runtime_config.variables)
          end
          # KE: May be here the code should be added
          # This code should call the CPI and create the subnets
          # also update the database
          if Config.network_lifecycle_enabled?
            deployment.networks.each do |network|
              if network.managed && !Bosh::Director::Models::Network.first(name: network.name)
                # call cpi to create network subnets
                network.subnets.each do |subnet|
                  cloud_factory = CloudFactory.create_with_latest_configs
                  cpi = cloud_factory.get_for_az(subnet.availability_zone_names[0])
                  # p "Got the cpi for the specific az"
                  # call cpi create_network on each subnet
                  network_create_results = cpi.create_subnet(subnet.vds_name, subnet.pg_name)
                  p "port name is #{port_name}"
                  p "cid is #{network_create_results["cid"]}"
                  # return values that will be stored in the database
                  subnet.cloud_properties = network_create_results["cloud_properties"]
                end

                # update the network database tables
                nw = Bosh::Director::Models::Network.new(name: network.name, type: "manual", cid: 5, created_at: Time.now)
                nw.save
                network.subnets.each do |subnet|
                  p "creating subnets #{subnet.cloud_properties}"
                  sn = Bosh::Director::Models::Subnet.new(range: subnet.range, gateway: subnet.gateway, dns: JSON.dump(subnet.dns), static: JSON.dump(subnet.static_ips.to_a), reserved: JSON.dump(subnet.restricted_ips.to_a), cloud_properties: JSON.dump(subnet.cloud_properties), az: JSON.dump(subnet.availability_zone_names))
                  nw.add_subnet(sn)
                  sn.save
                end
                deployment.model.add_network(nw)
                p "created network entry in the database #{network.name}"
              end
            end
          end

          if Config.network_lifecycle_enabled?
            deployment.networks.each do |network|
              if network.managed
                # fill the network details from the database
                # Shall we change the cloud config in the fly here?!! Probably not
              end
            end
          end

          DeploymentValidator.new.validate(deployment)

          # this returns a planner object
          deployment
        end

        def parse_tags(manifest_hash, runtime_config_consolidator)
          deployment_name = manifest_hash['name']
          tags = {}

          if manifest_hash.key?('tags')
            safe_property(manifest_hash, 'tags', class: Hash).each_pair do |key, value|
              tags[key] = value
            end
          end

          runtime_config_consolidator.tags(deployment_name).merge!(tags)
        end

        def validate_and_get_argument(arg, type)
          raise "#{type} value should be integer or percent" unless arg =~ /^\d+%$|\A[-+]?[0-9]+\z/ || arg.nil?
          arg
        end
      end
    end
  end
end
