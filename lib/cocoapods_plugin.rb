require 'cocoapods-localpodbinary/command'
require_relative 'cocoapods-localpodbinary/localpodbinary-consume'
require_relative 'cocoapods-localpodbinary/podfile-cache-option/podfile_private_api_hooks'

module LocalpodbinaryConsume
  Pod::HooksManager.register('cocoapods-localpodbinary', :post_install) do |context|
    LocalpodbinaryConsume::PodBinaryConsume.new.consume()
  end
  Pod::HooksManager.register('cocoapods-localpodbinary', :post_update) do |context|
    LocalpodbinaryConsume::PodBinaryConsume.new.consume()
  end
end