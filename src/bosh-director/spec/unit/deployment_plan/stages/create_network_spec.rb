require 'spec_helper'
require 'bosh/director/deployment_plan/multi_instance_group_updater'
require 'bosh/director/instance_group_updater'

module Bosh::Director
  module DeploymentPlan::Stages
    describe CreateNetworkStage do
        subject { CreateNetworkStage.new(logger, deployment_plan) }
        let(:cloud_factory) { instance_double(AZCloudFactory) }
        let(:cloud) { instance_double(Bosh::Clouds::ExternalCpi) }
        let(:deployment_model) { Models::Deployment.make(name: 'deployment_name') }
        let(:deployment_plan) do
            planner_attributes = {name: 'deployment_name', properties: {}}
            cloud_config = Bosh::Spec::Deployments.simple_cloud_config
            cloud_config['networks'] = [{
                'name' => 'a',
                'type' => 'manual',
                'managed' => true,
                'subnets' => [
                    {
                        'range' => '192.168.10.0/24',
                        'gateway' => '192.168.10.1',
                        'cloud_properties' => {'t0_id' => "123456"},
                        'dns' => ['8.8.8.8']
                    },
                    {
                        'range' => '192.168.20.0/24',
                        'gateway' => '192.168.20.1',
                        'cloud_properties' => {'t0_id' => "123456"},
                        'dns' => ['8.8.8.8']
                    }
                ],
            }]
            manifest = Bosh::Spec::Deployments.simple_manifest
            planner = DeploymentPlan::Planner.new(planner_attributes, manifest, YAML.dump(manifest), [Models::Config.make(:cloud, content: YAML.dump(cloud_config))], Bosh::Spec::Deployments.simple_runtime_config, deployment_model)
      
            planner.cloud_planner = DeploymentPlan::CloudManifestParser.new(logger).parse(cloud_config,
              DeploymentPlan::GlobalNetworkResolver.new(planner, [], logger),
              DeploymentPlan::IpProviderFactory.new(true, logger))
            planner.update = DeploymentPlan::UpdateConfig.new(manifest['update'])
      
            planner
        end
        describe '#perform' do
            before do
                allow(Config).to receive(:network_lifecycle_enabled?).and_return(true)
                allow(AZCloudFactory).to receive(:create_with_latest_configs).and_return(cloud_factory)
                allow(cloud_factory).to receive(:get).and_return(cloud)
            end
            it 'creates all subnets successfully' do
                expect(cloud).to receive(:create_subnet).with(hash_including('gateway' => '192.168.10.1')).and_return({'network_cid' => '12345', 'cloud_properties' => {'name': 'dummy1'}})
                expect(cloud).to receive(:create_subnet).with(hash_including('gateway' => '192.168.20.1')).and_return({'network_cid' => '67890', 'cloud_properties' => {'name': 'dummy2'}})
                subject.perform
            end

            it 'cleans up subnets on failure' do
                expect(cloud).to receive(:create_subnet).with(hash_including('gateway' => '192.168.10.1')).and_return({'network_cid' => '12345', 'cloud_properties' => {'name': 'dummy1'}})
                expect(cloud).to receive(:create_subnet).with(hash_including('gateway' => '192.168.20.1')).and_raise("cpi error")
                expect(cloud).to receive(:delete_subnet).with('12345')
                expect { subject.perform }.to raise_error
            end
        end
    end
  end
end