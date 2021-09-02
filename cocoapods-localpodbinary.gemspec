# coding: utf-8
lib = File.expand_path('../lib', __FILE__)
$LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)
require 'cocoapods-localpodbinary/gem_version.rb'

Gem::Specification.new do |spec|
  spec.name          = 'cocoapods-localpodbinary'
  spec.version       = CocoapodsLocalpodbinary::VERSION
  spec.authors       = ['styf']
  spec.email         = ['174481103@qq.com']
  spec.description   = %q{A short description of cocoapods-localpodbinary.}
  spec.summary       = %q{A longer description of cocoapods-localpodbinary.}
  spec.homepage      = 'https://github.com/EXAMPLE/cocoapods-localpodbinary'
  spec.license       = 'MIT'

  # spec.files         = `git ls-files`.split($/)
  spec.files = Dir['lib/**/*']
  #spec.executables   = spec.files.grep(%r{^bin/}) { |f| File.basename(f) }
  spec.bindir        = "bin"
  spec.executables   = "localpodbinary"
  spec.test_files    = spec.files.grep(%r{^(test|spec|features)/})
  spec.require_paths = ['lib']

  # spec.add_development_dependency 'bundler', '~> 1.3'
  spec.add_development_dependency 'rake'

  spec.add_dependency "xcodeproj", "~> 1.19"
end
