Sequel.migration do
    # Create the three tables required for bosh managed networks
    change do
        create_table :networks do
            primary_key :id
            String :name, null: false
            String :cid, null: false
            String :type, null: false
            Time :created_at, null: false
            Boolean :orphaned, :default => false
            Time :orphaned_at
            index :name, unique: true
        end

        create_table :subnets do
            primary_key :id
            String :range
            String :gateway
            String :dns
            String :reserved
            String :static
            String :az
            String :cloud_properties
            foreign_key :network_id, :networks, :null => false, :on_delete => :cascade
        end

        create_table :deployments_networks do
            foreign_key :deployment_id, :deployments, :null => false, :on_delete => :cascade
            foreign_key :network_id, :networks, :null => false, :on_delete => :cascade
            unique [:deployment_id, :network_id], :name => :deployment_id_network_id_unique
        end
    end
end