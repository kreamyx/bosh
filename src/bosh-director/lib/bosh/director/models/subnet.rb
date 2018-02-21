module Bosh::Director::Models
    class Sybnet < Sequel::Model(Bosh::Director::Config.db)
        many_to_one :network
      
        # add validation later
  
    end
end