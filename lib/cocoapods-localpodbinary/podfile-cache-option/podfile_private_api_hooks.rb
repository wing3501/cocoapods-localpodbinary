require_relative '../localpodbinary/localpodbinary'

module Pod
  class CacheUserOption
    def self.keyword
      :cache_type
    end

  end

  class Podfile
    class TargetDefinition
      @@root_pod_cache_building_options = Hash.new

      def self.root_pod_cache_building_options
        @@root_pod_cache_building_options
      end

      # ======================
      # ==== PATCH METHOD ====
      # ======================
      swizzled_parse_subspecs = instance_method(:parse_subspecs)
      # 这一步：主要是收集信息，恢复options
      # HOOK配置，cache_type，写入到root_pod_cache_building_options
      # 使用 pod 'AFNetworking', '~> 4.0.0',:cache_type => false
      UI.puts "localpodbinary 开始hook parse_subspecs方法，收集cache_type信息"
      define_method(:parse_subspecs) do |name, requirements|
        building_options = @@root_pod_cache_building_options
        pod_name = Specification.root_name(name)
        options = requirements.last

        #UI.puts "localpodbinary Hooked Cocoapods parse_subspecs function to obtain Pod options. #{pod_name}"
        if options.is_a?(Hash)
          options.each do |k,v|
            next if not options.key?(Pod::CacheUserOption.keyword)

            user_cache_type = options.delete(k)
            building_options[pod_name] = user_cache_type
            UI.puts "#{pod_name} cache type set to: #{user_cache_type}"
          end
          requirements.pop if options.empty?
        end
        # Call old method
        swizzled_parse_subspecs.bind(self).(name, requirements)
      end
    end
  end
end

module Pod
  #给target扩展一个属性
  class Target
    # @return [BuildTarget]
    attr_accessor :user_defined_cache_type
  end

  class Installer
    # Walk through pod dependencies and assign build_type from root through all transitive dependencies
    # 这一步是给每个target设置user_defined_cache_type，包括依赖项
    # 如果某个库指定了build_type，这个库所依赖的库也指定build_type，把build_type放到自定义属性user_defined_cache_type中
    def resolve_all_pod_cache_types(pod_targets)
      root_pod_cache_building_options = Pod::Podfile::TargetDefinition.root_pod_cache_building_options.clone
      pod_targets.each do |target|
        next if not root_pod_cache_building_options.key?(target.name)

        cache_type = root_pod_cache_building_options[target.name]
        dependencies = target.dependent_targets

        # Cascade build_type down
        while not dependencies.empty?
          new_dependencies = []
          dependencies.each do |dep_target|
            dep_target.user_defined_cache_type = cache_type
            new_dependencies.push(*dep_target.dependent_targets)
          end
          dependencies = new_dependencies
        end

        target.user_defined_cache_type = cache_type
      end
    end

    # ======================
    # ==== PATCH METHOD ====
    # ======================

    # Store old method reference
    swizzled_analyze = instance_method(:analyze)

    # Swizzle 'analyze' cocoapods core function to finalize build settings
    define_method(:analyze) do |analyzer = create_analyzer|
      # Run original method
      swizzled_analyze.bind(self).(analyzer)

      resolve_all_pod_cache_types(pod_targets)

      cache_hash = {}
      pod_targets.each do |target|
        #UI.puts "打印一下属性 #{target.instance_variables}"
        # [:@sandbox, :@user_build_configurations, :@archs, :@platform, :@build_type,
        # :@application_extension_api_only, :@build_library_for_distribution, :@build_settings, :@specs,
        # :@target_definitions, :@file_accessors, :@scope_suffix, :@swift_version, :@library_specs, :@test_specs,
        # :@app_specs, :@build_headers, :@dependent_targets, :@dependent_targets_by_config,
        # :@test_dependent_targets_by_spec_name, :@test_dependent_targets_by_spec_name_by_config,
        # :@app_dependent_targets_by_spec_name, :@app_dependent_targets_by_spec_name_by_config, :@test_app_hosts_by_spec,
        # :@build_config_cache, :@test_spec_build_settings_by_config, :@app_spec_build_settings_by_config]
        # 输出类信息
        #UI.puts "Class of target = #{target.class}" #Pod::PodTarget

        # Pod::PodTarget
        # UI.puts "Name of target = #{target.name}" #ZXingObjC
        # UI.puts "specs of target = #{target.specs}"
        # UI.puts "target_definitions of target = #{target.target_definitions}"

        # Name of target = WPTWebModule
        # specs of target = [#<Pod::Specification name="WPTWebModule">, #<Pod::Specification name="WPTWebModule/BaseView">, #<Pod::Specification name="WPTWebModule/Core">]
        # target_definitions of target = [#<Pod::Podfile::TargetDefinition label=Pods-XXXX>]
        # Pod::Podfile::TargetDefinition

        # UI.puts "-------------"
        #

        #⚠️没有找到合适的属性，所以写到文件中
        # 目前，只收集不需要缓存的库用于过滤
        #next if not target.user_defined_cache_type.present?
        if target.user_defined_cache_type == false
          cache_hash[target.name] = false
        else
          cache_hash[target.name] = true
        end
      end
      #UI.puts "localpodbinary result = #{cache_hash}"  #result = {"AFNetworking"=>false}
      #UI.puts "PATH = #{Dir.pwd}" #/Users/styf/Documents/workspace/xxxxx
      cache_file_path = Dir.pwd + "/" + Localpodbinary::FILE_NAME_CACHE
      UI.puts "localpodbinary 将podfile中的pod本地缓存配置写入到:#{cache_file_path}"
      #⚠️暂时先写到主工程目录下
      File.write(cache_file_path, cache_hash.to_yaml)
    end

  end
end