require 'cocoapods'
require_relative 'localpodbinary/localpodbinary'

module LocalpodbinaryConsume
  class PodBinaryConsume
    def consume
      Pod::UI.puts "开始消费------"
       Localpodbinary::consume
    end
  end
end
