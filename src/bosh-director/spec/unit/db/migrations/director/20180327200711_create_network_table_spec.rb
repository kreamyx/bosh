require_relative '../../../../db_spec_helper'

module Bosh::Director
  describe 'create_managed_network_tables' do
    let(:db) { DBSpecHelper.db }
    let(:migration_file) { '20180327200711_create_network_table.rb' }
    let(:created_at) { Time.now.utc }

    before do
      DBSpecHelper.migrate_all_before(migration_file)

      db[:deployments] << {
        id: 42,
        name: 'fake_deployment'
      }

      db[:deployments] << {
        id: 28,
        name: 'fake_deployment_2'
      }
    end

    it 'creates all tables for managed networks' do
      DBSpecHelper.migrate(migration_file)

      db[:networks] << {
        name: 'test_network_1',
        type: 'manual',
        created_at: created_at
      }

      # expect(db[:networks].first).to eq({
      #   id: 1,
      #   name: 'test_network_1',
      #   type: 'manual',
      #   orphaned_at: nil,
      #   created_at: created_at,
      #   orphaned: false
      # })

      db[:subnets] << {
        cid: 'subnetid-12345',
        order: 0,
        cloud_properties: '{"name": "subnet-name"}',
        network_id: 1
      }

      expect(db[:subnets].first).to eq({
        id: 1,
        cid: 'subnetid-12345',
        order: 0,
        cloud_properties: '{"name": "subnet-name"}',
        network_id: 1
      })

      db[:deployments_networks] << {
        deployment_id: 42,
        network_id: 1
      }

      expect(db[:deployments_networks].first).to eq({
        deployment_id: 42,
        network_id: 1
      })
    end
  end
end
