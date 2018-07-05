module Bosh::Director
  module Jobs
    class DeleteOrphanNetworks < BaseJob
      @queue = :normal

      def self.job_type
        :delete_orphan_networks
      end

      def self.enqueue(username, orphan_network_names, job_queue)
        unorphaned_networks = orphan_network_names.select do |network_name|
          Bosh::Director::Models::Network.where(name: network_name, orphaned: false).any?
        end
        if unorphaned_networks.any?
          raise DeletingUnorphanedNetworkError, "Deleting unorphaned network is not supported: #{orphan_network_names}"
        end

        job_queue.enqueue(username, Jobs::DeleteOrphanNetworks, 'delete orphan networks', [orphan_network_names])
      end

      def initialize(orphan_network_names)
        @orphan_network_names = orphan_network_names
        @orphan_network_manager = OrphanNetworkManager.new(Config.logger)
      end

      def perform
        event_log_stage = Config.event_log.begin_stage('Deleting orphaned networks', @orphan_network_names.count)
        ThreadPool.new(max_threads: Config.max_threads).wrap do |pool|
          @orphan_network_names.each do |orphan_network_name|
            pool.process do
              event_log_stage.advance_and_track("Deleting orphaned network #{orphan_network_name}") do
                @orphan_network_manager.delete_network(orphan_network_name)
              end
            end
          end
        end
        "orphaned network(s) #{@orphan_network_names.join(', ')} deleted"
      end
    end
  end
end