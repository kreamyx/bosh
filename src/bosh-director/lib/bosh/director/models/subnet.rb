module Bosh::Director::Models
    class Subnet < Sequel::Model(Bosh::Director::Config.db)
        many_to_one :network
      
        # add validation later
  
    end
end