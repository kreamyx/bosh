module Bosh::Director
  module DeploymentPlan
    class DynamicNetworkSubnet
      def initialize(dns, cloud_properties, availability_zone_names)
        @dns = dns
        @cloud_properties = cloud_properties
        @availability_zone_names = availability_zone_names.nil? ? nil : availability_zone_names
      end

      attr_reader :dns, :availability_zone_names
      # ToDo: Besides cloud properties, what else should be writable?
      attr_accessor :cloud_properties
    end
  end
end
