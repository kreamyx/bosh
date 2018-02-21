module Bosh::Director::Models
    class Network < Sequel::Model(Bosh::Director::Config.db)
  
      VALID_PROPERTY_NAME = /^[-a-z0-9_.]+$/i
      many_to_many :deployments
      one_to_many :subnets
      
      def validate
        validates_presence :name
        validates_unique :name
  
        validates_format VALID_PROPERTY_NAME, :name, :allow_blank => true
      end
  
    end
end
  