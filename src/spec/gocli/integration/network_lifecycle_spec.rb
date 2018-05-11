require_relative '../spec_helper'


describe 'network lifecycle feature disabled', type: :integration do
    with_reset_sandbox_before_each

    before { bosh_runner.reset }
    context 'cli' do
        it 'prints out the feature is disabled in cli env' do
            out = bosh_runner.run('env')
            expect(out).to include("network_lifecycle: disabled")
        end
    end

    context 'when deploying a manifest with a manual network marked as managed' do
        it 'should not attempt to create a subnet in the iaas' do
            cloud_config_hash = Bosh::Spec::NewDeployments.simple_cloud_config
            cloud_config_hash['networks'] = [{
                'name' => 'a',
                'type' => 'manual',
                'managed' => true,
                'subnets' => [
                    {
                        'range' => '192.168.10.0/24',
                        'gateway' => '192.168.10.1',
                        'cloud_properties' => {'t0_id' => "123456"},
                        'dns' => ['8.8.8.8']
                    }
                ],
            }]

            manifest_hash = Bosh::Spec::NewDeployments.simple_manifest_with_instance_groups
            manifest_hash['instance_groups'].first['instances'] = 1
            manifest_hash['instance_groups'].first['networks'] = [{'name' => 'a'}]
            upload_cloud_config(cloud_config_hash: cloud_config_hash)
            deploy_from_scratch(cloud_config_hash: cloud_config_hash, manifest_hash: manifest_hash)
            create_subnet_invocations = current_sandbox.cpi.invocations_for_method('create_subnet')
            expect(create_subnet_invocations.count).to eq(0)
        end
    end
end

describe 'network lifecycle feature enabled', type: :integration do
    with_reset_sandbox_before_each(network_lifecycle: {'enabled' => true})
    before { bosh_runner.reset }

    context 'cli' do
        it 'prints out the feature is enabled in cli env' do
            out = bosh_runner.run('env')
            expect(out).to include("network_lifecycle: enabled")
        end
    end

    context 'when deploying a manifest with a managed network' do
        it 'should create a subnet in the iaas for first deployment' do
            cloud_config_hash = Bosh::Spec::NewDeployments.simple_cloud_config
            cloud_config_hash['networks'] = [{
                'name' => 'a',
                'type' => 'manual',
                'managed' => true,
                'subnets' => [
                    {
                        'range' => '192.168.10.0/24',
                        'gateway' => '192.168.10.1',
                        'cloud_properties' => {'t0_id' => "123456"},
                        'dns' => ['8.8.8.8']
                    }
                ],
            }]

            manifest_hash = Bosh::Spec::NewDeployments.simple_manifest_with_instance_groups
            manifest_hash['instance_groups'].first['instances'] = 1
            manifest_hash['instance_groups'].first['networks'] = [{'name' => 'a'}]
            upload_cloud_config(cloud_config_hash: cloud_config_hash)
            deploy_from_scratch(cloud_config_hash: cloud_config_hash, manifest_hash: manifest_hash)
            create_subnet_invocations = current_sandbox.cpi.invocations_for_method('create_subnet')
            expect(create_subnet_invocations.count).to eq(1)
            subnet_invocation = create_subnet_invocations.first
            expect(subnet_invocation.inputs["subnet_definition"]).to eq({"range"=>"192.168.10.0/24", "cloud_properties"=>{"t0_id"=>"123456"}, "gateway"=>"192.168.10.1"})      
        end

        it 'should not create a subnet in the iaas for following deployments' do
            cloud_config_hash = Bosh::Spec::NewDeployments.simple_cloud_config
            cloud_config_hash['networks'] = [{
                'name' => 'a',
                'type' => 'manual',
                'managed' => true,
                'subnets' => [
                    {
                        'range' => '192.168.10.0/24',
                        'gateway' => '192.168.10.1',
                        'cloud_properties' => {'t0_id' => "123456"},
                        'dns' => ['8.8.8.8']
                    }
                ],
            }]

            manifest_hash = Bosh::Spec::NewDeployments.simple_manifest_with_instance_groups
            manifest_hash['instance_groups'].first['instances'] = 1
            manifest_hash['instance_groups'].first['networks'] = [{'name' => 'a'}]
            upload_cloud_config(cloud_config_hash: cloud_config_hash)
            deploy_from_scratch(cloud_config_hash: cloud_config_hash, manifest_hash: manifest_hash)
            
            3.times do |i|
                manifest_hash['name'] = "another-deployment-#{i}"
                manifest_hash['instance_groups'].first['instances'] = 1
                manifest_hash['instance_groups'].first['networks'] = [{'name' => 'a'}]
                deploy_simple_manifest(cloud_config_hash: cloud_config_hash, manifest_hash: manifest_hash)
            end
            
            create_subnet_invocations = current_sandbox.cpi.invocations_for_method('create_subnet')
            expect(create_subnet_invocations.count).to eq(1)
        end

        it 'should fetch valid subnet definitions for following deployments' do
            cloud_config_hash = Bosh::Spec::NewDeployments.simple_cloud_config
            cloud_config_hash['networks'] = [{
                'name' => 'a',
                'type' => 'manual',
                'managed' => true,
                'subnets' => [
                    {
                        'range' => '192.168.10.0/24',
                        'gateway' => '192.168.10.1',
                        'cloud_properties' => {'t0_id' => "123456"},
                        'dns' => ['8.8.8.8']
                    }
                ],
            }]

            manifest_hash = Bosh::Spec::NewDeployments.simple_manifest_with_instance_groups
            manifest_hash['instance_groups'].first['instances'] = 1
            manifest_hash['instance_groups'].first['networks'] = [{'name' => 'a'}]
            upload_cloud_config(cloud_config_hash: cloud_config_hash)
            deploy_from_scratch(cloud_config_hash: cloud_config_hash, manifest_hash: manifest_hash)
            create_vm_invocation = current_sandbox.cpi.invocations_for_method('create_vm').last
            network_cid = create_vm_invocation.inputs['networks']['a']['cloud_properties']['name']
            3.times do |i|
                manifest_hash['name'] = "another-deployment-#{i}"
                manifest_hash['instance_groups'].first['instances'] = 1
                manifest_hash['instance_groups'].first['networks'] = [{'name' => 'a'}]
                deploy_simple_manifest(cloud_config_hash: cloud_config_hash, manifest_hash: manifest_hash)
                create_vm_invocation = current_sandbox.cpi.invocations_for_method('create_vm').last
                expect(create_vm_invocation.inputs['networks']['a']['cloud_properties']).to eq({"name" => network_cid})
            end
        end

        it 'should not accept a dynamic network marked as managed' do
            cloud_config_hash = Bosh::Spec::NewDeployments.simple_cloud_config
            cloud_config_hash['networks'] = [{
                'name' => 'a',
                'type' => 'dynamic',
                'managed' => true
            }]

            manifest_hash = Bosh::Spec::NewDeployments.simple_manifest_with_instance_groups
            manifest_hash['instance_groups'].first['instances'] = 1
            manifest_hash['instance_groups'].first['networks'] = [{'name' => 'a'}]
            upload_cloud_config(cloud_config_hash: cloud_config_hash)
            deploy_from_scratch(cloud_config_hash: cloud_config_hash, manifest_hash: manifest_hash)
            create_subnet_invocations = current_sandbox.cpi.invocations_for_method('create_subnet')
            expect(create_subnet_invocations.count).to eq(0)
        end
    end

    # Write Another Integration Test For Cleanup When Create_Subnet FAILS 
end