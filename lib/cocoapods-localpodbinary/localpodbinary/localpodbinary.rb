
require 'xcodeproj'
require 'digest'
require 'set'
require 'open3'
require "find"
require 'yaml'
require 'pathname'
require_relative '../gem_version'

module Localpodbinary
  class Error < StandardError; end

  BUILD_KEY_SYMROOT = "SYMROOT"
  BUILD_KEY_CONFIGURATION_BUILD_DIR = "CONFIGURATION_BUILD_DIR"
  BUILD_KEY_TARGET_BUILD_DIR = "TARGET_BUILD_DIR"
  BUILD_KEY_OBJROOT = "OBJROOT"
  BUILD_KEY_TARGET_TEMP_DIR = "TARGET_TEMP_DIR"
  BUILD_KEY_PODS_XCFRAMEWORKS_BUILD_DIR = "PODS_XCFRAMEWORKS_BUILD_DIR"
  BUILD_KEY_MODULEMAP_FILE = "MODULEMAP_FILE"
  BUILD_KEY_SRCROOT = "SRCROOT"
  BUILD_KEY_FULL_PRODUCT_NAME = "FULL_PRODUCT_NAME"
  BUILD_KEY_CONFIGURATION = "CONFIGURATION"

  STATUS_HIT = "hit"
  STATUS_MISS = "miss"

  STAGE_PRODUCE = "produce"
  STAGE_CONSUME = "consume"
  STAGE_PRINTENV = "printenv"
  STAGE_CLREAN = "clean"
  STAGE_USE = "use"

  FILE_NAME_MESSAGE = "message.txt"
  FILE_NAME_CONTEXT = "context.yml"
  FILE_NAME_PRODUCT = "product.tar"
  FILE_NAME_TARGET_CONTEXT = "localpodbinary_target_context.yml"
  FILE_NAME_CACHE = "pod_cache.txt"

  PRODUCE_SHELL_NAME = "localpodbinary_produce"

  def self.lpb_get_cache_root
    cache_root = ENV["LPB_CACHE_ROOT"]
    if cache_root and cache_root.size > 0
      return cache_root
    end

    return Dir.home + "/localPodBinary"
  end

  def self.lpb_get_cache_count
    cache_count = ENV["LPB_CACHE_COUNT"]
    if cache_count and cache_count.to_i.to_s == cache_count
      return cache_count.to_i
    end
    return 10000
  end

  def self.lpb_should_not_detect_module_map_dependency
    # By default, localPodBinary detects module map dependency.
    # However, there are bugs of xcodebuild or swift-frontend, which emits unnecessary and incorrect modulemap dependencies.
    # To test by run "ruby test/one.rb test/todo/modulemap_file/Podfile"
    # To avoid by set "export LPB_NOT_DETECT_MODULE_MAP_DEPENDENCY=YES"
    lpb_should_not_detect_module_map_dependency = ENV["LPB_NOT_DETECT_MODULE_MAP_DEPENDENCY"]
    if lpb_should_not_detect_module_map_dependency == "YES"
      return true
    end
    return false
  end

  #返回最小缓存文件数量
  def self.lpb_get_min_source_file_count
    # By default, localPodBinary caches targets which count of source files is greater than or equal 1.
    # You can set this value to 0 or more than 1 to achieve higher speed.
    min_source_file_count = ENV["LPB_MIN_SOURCE_FILE_COUNT"]
    if min_source_file_count and min_source_file_count.to_i.to_s == min_source_file_count
      return min_source_file_count.to_i
    end
    return 1
  end

  #拿到所有xcodeproj工程对象
  def self.lpb_get_projects
    # TODO: to support more project, not only Pods
    pods_project = Xcodeproj::Project.open("Pods/Pods.xcodeproj")
    wrapper_project_paths = lpb_get_wrapper_project_paths(pods_project) #[/Users/styf/Downloads/ruby_app/ZabelTest/ZabelAPP/Pods/SDWebImage.xcodeproj,...]
    wrapper_projects = []
    wrapper_project_paths.each do | path |
      next if path.end_with? "Pods/Pods.xcodeproj"
      project = Xcodeproj::Project.open(path)
      wrapper_projects.push project
    end
    return (wrapper_projects + [pods_project]) #[SDWebImage.xcodeproj,AFNetworking.xcodeproj,Pods.xcodeproj]
  end

  #拿到主工程
  def self.lpb_get_main_project
    main_xcodeproj_path_array = Dir.glob("*.xcodeproj")
    if main_xcodeproj_path_array.size == 0
      # 我们的项目的工程是放在下一级文件夹下面的，其他项目一般放在一级目录
      main_xcodeproj_path_array = Dir.glob("#{File.basename(Dir.pwd.to_s)}/*.xcodeproj")
    end
    if main_xcodeproj_path_array.size == 0
      puts "[LPB/E] 主工程不存在"
      return
    end
    main_xcodeproj_path = main_xcodeproj_path_array[0]
    puts "[LPB/I] 主工程路径：#{main_xcodeproj_path}"
    main_project = Xcodeproj::Project.open(main_xcodeproj_path)
    return main_project
  end

  #拿到和主工程同名的target
  def self.lpb_get_main_target(main_project,main_project_name)
    main_target = nil

    main_project.native_targets.each do | target |
      if target.name == main_project_name #暂时先这么判断，没想到更好的办法
        main_target = target
        break
      end
    end

    unless main_target
      puts "[LPB/E] 同名主工程的target没有找到"
    end
    return main_target
  end

  # 删除主target的生产脚本
  def self.lpb_delete_main_target_produce_shell(main_project,main_target)
    main_target.build_phases.delete_if { | build_phase |
      build_phase.class == Xcodeproj::Project::Object::PBXShellScriptBuildPhase and build_phase.name == PRODUCE_SHELL_NAME
    }
    main_project.save
    puts "[LPB/I] 删除主工程生产脚本"
  end

  # 从Pods.xcodeproj找到所有第三方库的工程，文件类型是wrapper.pb-project
  # 得到路径数组
  # SDWebImage
  # wrapper.pb-project
  # /Users/styf/Downloads/ruby_app/ZabelTest/ZabelAPP/Pods/SDWebImage.xcodeproj
  def self.lpb_get_wrapper_project_paths(project)
    wrapper_projects = project.files.select{|file|file.last_known_file_type=="wrapper.pb-project"}
    wrapper_project_paths = []
    wrapper_projects.each do | wrapper_project_file |
      wrapper_project_file_path = wrapper_project_file.real_path.to_s
      wrapper_project_paths.push wrapper_project_file_path
    end
    return wrapper_project_paths.uniq
  end

  $cache_hash = {}
  $has_load_cache_file = false
  # target能否缓存   只缓存三种产品类型
  def self.lpb_can_cache_target(target)
    if target.name.start_with? "Pods-"
      puts "[LPB/I] skip #{target.name}"
      return false
    end

    # 手动在podfile配置中 不需要缓存的库信息
    if $has_load_cache_file == false
      $has_load_cache_file = true
      cache_file_path = Dir.pwd + "/" + FILE_NAME_CACHE
      if File.exist? cache_file_path
        puts "[LPB/I] 手动配置的podfile缓存信息存在"
        $cache_hash = YAML.load(File.read(cache_file_path))
      else
        puts "[LPB/I] 手动配置的podfile缓存信息存在 path:#{cache_file_path}"
      end
    end
    # 含有资源的库会有多个target,过滤的时候一起过滤
    # WPTAllSeeingEyeModule
    # WPTAllSeeingEyeModule-WPTAESBundle
    split_parts = target.name.split("-")
    target_name = split_parts[0]
    if $cache_hash.has_key? target_name
      if $cache_hash[target_name] == false
        puts "[LPB/I] skip #{target.name} by cache_type in podfile"
        return false
      end
    end

    if target.class == Xcodeproj::Project::Object::PBXNativeTarget
      # see https://github.com/CocoaPods/Xcodeproj/blob/master/lib/xcodeproj/constants.rb#L145
      if target.product_type == "com.apple.product-type.bundle" or
        target.product_type == "com.apple.product-type.library.static" or
        target.product_type == "com.apple.product-type.framework"
        return true
      else
        puts "[LPB/I] skip #{target.name} #{target.class} #{target.product_type}"
      end
    else
      puts "[LPB/I] skip #{target.name} #{target.class}"
    end
    return false
  end

  # 获取所有依赖文件
  # Xcode使用clang或swift编译时，默认都会生成.d的依赖分析结果在中间产物目录，里面包含某个文件编译时所需的所有头文件。
  # dependencies: \
  #   /Users/dengweijun/xxx/Pods/YYWebImage/YYWebImage/YYWebImageManager.m \
  #   /Users/dengweijun/xxx/Pods/Target\ Support\ Files/YYWebImage/YYWebImage-prefix.pch \
  #   /Applications/Xcode.app/Contents/Developer/Platforms/iPhoneOS.platform/Developer/SDKs/iPhoneOS14.5.sdk/usr/include/mach-o/compact_unwind_encoding.modulemap \
  #   /Applications/Xcode.app/Contents/Developer/Platforms/iPhoneOS.platform/Developer/SDKs/iPhoneOS14.5.sdk/usr/include/mach-o/dyld.modulemap \
  #   /Users/dengweijun/xxx/Pods/YYWebImage/YYWebImage/YYWebImageManager.h \
  #   /Users/dengweijun/xxx/Pods/YYWebImage/YYWebImage/YYWebImage.h \
  #   /Users/dengweijun/xxx/Pods/YYWebImage/YYWebImage/YYImageCache.h \
  #   /Users/dengweijun/xxx/Pods/YYWebImage/YYWebImage/YYWebImageOperation.h \
  #   /Users/dengweijun/xxx/Pods/Headers/Private/YYImage/YYImage.h \
  #   /Users/dengweijun/xxx/Pods/Headers/Private/YYImage/YYFrameImage.h \
  #   /Users/dengweijun/xxx/Pods/Headers/Private/YYImage/YYAnimatedImageView.h \
  #   /Users/dengweijun/xxx/Pods/Headers/Private/YYImage/YYSpriteSheetImage.h \
  #   /Users/dengweijun/xxx/Pods/Headers/Private/YYImage/YYImageCoder.h
  def self.lpb_get_dependency_files(target, intermediate_dir, product_dir, xcframeworks_build_dir)
    dependency_files = []
    Dir.glob("#{intermediate_dir}/**/*.d").each do | dependency_file |
      content = File.read(dependency_file)
      # see https://github.com/ccache/ccache/blob/master/src/Depfile.cpp#L141
      # and this is a simple regex parser enough to get all files, as far as I know.
      files = content.scan(/(?:\S(?:\\ )*)+/).flatten.uniq
      files = files - ["dependencies:", "\\", ":"]

      files.each do | file |
        file = file.gsub("\\ ", " ")

        unless File.exist? file
          puts "[LPB/E] #{target.name} #{file} should exist in dependency file #{dependency_file}"
          return []
        end

        if file.start_with? intermediate_dir + "/" or
          file.start_with? product_dir + "/" or
          file.start_with? xcframeworks_build_dir + "/"
          next
        end

        dependency_files.push file
      end
    end
    return dependency_files.uniq
  end

  #收集编译文件、头文件、资源文件的路径
  def self.lpb_get_target_source_files(target)
    files = []

    # 参与编译的文件路径
    #/Users/styf/Downloads/ruby_app/ZabelTest/ZabelAPP/Pods/Target Support Files/MJRefresh/MJRefresh-dummy.m
    # /Users/styf/Downloads/ruby_app/ZabelTest/ZabelAPP/Pods/MJRefresh/MJRefresh/Base/MJRefreshAutoFooter.m
    target.source_build_phase.files.each do | file |
      file_path = file.file_ref.real_path.to_s
      files.push file_path

    end

    # 头文件路径
    # /Users/styf/Downloads/ruby_app/ZabelTest/ZabelAPP/Pods/MJRefresh/MJRefresh/MJRefresh.h
    # /Users/styf/Downloads/ruby_app/ZabelTest/ZabelAPP/Pods/MJRefresh/MJRefresh/Base/MJRefreshAutoFooter.h
    target.headers_build_phase.files.each do | file |
      file_path = file.file_ref.real_path.to_s
      files.push file_path

    end

    # 资源文件路径  bundle类型的target所需要的资源文件
    target.resources_build_phase.files.each do | file |
      file_path = file.file_ref.real_path.to_s
      files.push file_path

    end

    expand_files = []
    files.uniq.each do | file |
      next unless File.exist? file
      if File.file? file
        expand_files.push file
      else
        # 路径是文件夹，就遍历文件夹
        Find.find(file).each do | file_in_dir |
          if File.file? file_in_dir
            expand_files.push file_in_dir
          end
        end
      end
    end
    return expand_files.uniq
  end

  #去掉绝对路径 比如 /Users/styf/Downloads/ruby_app/ZabelTest/ZabelAPP/
  def self.lpb_get_content_without_pwd(content)
    content = content.gsub("#{Dir.pwd}/", "").gsub(/#{Dir.pwd}(\W|$)/, '\1')
    return content
  end

  $lpb_file_md5_hash = {}
  #计算文件的md5值
  def self.lpb_get_file_md5(file)
    if $lpb_file_md5_hash.has_key? file
      return $lpb_file_md5_hash[file]
    end
    md5 = Digest::MD5.hexdigest(File.read(file))
    $lpb_file_md5_hash[file] = md5
    return md5
  end

  # 超过最大缓存数则清理
  def self.lpb_keep
    file_list = Dir.glob("#{lpb_get_cache_root}/*")
    file_time_hash = {}
    file_list.each do | file |
      file_time_hash[file] = File.mtime(file)
    end
    file_list = file_list.sort_by {|file| - file_time_hash[file].to_f}
    puts "[LPB/I] keep cache " + file_list.size.to_s + " " + Open3.capture3("du -sh #{lpb_get_cache_root}")[0].to_s

    if file_list.size > 1
      puts "[LPB/I] keep oldest " + file_time_hash[file_list.last].to_s + " " + file_list.last
      puts "[LPB/I] keep newest " + file_time_hash[file_list.first].to_s + " " + file_list.first
    end

    if file_list.size > lpb_get_cache_count
      file_list_remove = file_list[lpb_get_cache_count..(file_list.size-1)]
      file_list_remove.each do | file |
        raise unless system "rm -rf \"#{file}\""
      end
    end
  end

  # 删除备份工程
  def self.lpb_clean_backup_project(project)
    command = "rm -rf \"#{project.path}/project.localpodbinary_backup_pbxproj\""
    raise unless system command
  end

  # 备份工程
  def self.lpb_backup_project(project)
    command = "cp \"#{project.path}/project.pbxproj\" \"#{project.path}/project.localpodbinary_backup_pbxproj\""
    raise unless system command
  end
  # 从备份工程还原
  def self.lpb_restore_project(project)
    if File.exist? "#{project.path}/project.localpodbinary_backup_pbxproj"
      command = "mv \"#{project.path}/project.localpodbinary_backup_pbxproj\" \"#{project.path}/project.pbxproj\""
      puts command
      raise unless system command
    end
  end
  # 删除上下文信息文件
  def self.lpb_delete_target_context_file(project,target)
    if File.exist? "#{project.path}/#{target.name}.#{FILE_NAME_TARGET_CONTEXT}"
      command = "rm -rf \"#{project.path}/#{target.name}.#{FILE_NAME_TARGET_CONTEXT}\""
      raise unless system command
    end
  end

  $lpb_podfile_spec_checksums = nil
  # 获取工程信息 包含
  # Localpodbinary version
  # ARGV 传入的关键参数，去除登出地址等参数
  # pod.lockfile文件中匹配到的SPEC CHECKSUMS
  # project的build_configuration信息 (根据configuration_name取对应的)
  # project的xcconfig (不含SEARCH_PATHS)
  # target的build_configuration信息 (根据configuration_name取对应的)
  # target的xcconfig (不含SEARCH_PATHS)
  # 单个文件配置 Files settings
  #
  def self.lpb_get_target_md5_content(project, target, configuration_name, argv, source_files)

    #读取 Podfile.lock的 SPEC CHECKSUMS数组
    # SPEC CHECKSUMS:
    #   AFNetworking: 56044b835c538bda33e7f3463b15e18385d10c20
    #   MJRefresh: 2e77cd93502d4cccf6e6fa24231b0284b9959d69
    #   SDWebImage: 8e66002b0343b182c1a9d53073bd1c82009e183a
    unless $lpb_podfile_spec_checksums
      if File.exist? "Podfile.lock"
        podfile_lock = YAML.load(File.read("Podfile.lock"))
        $lpb_podfile_spec_checksums = podfile_lock["SPEC CHECKSUMS"]
      end
    end
    # project的build setting
    project_configuration = project.build_configurations.detect { | config | config.name == configuration_name}
    project_configuration_content = project_configuration.pretty_print.to_yaml
    # puts project_configuration_content

    #查找project的xcconfig文件
    project_xcconfig = ""
    if project_configuration.base_configuration_reference  #an optional file reference to a configuration file (`.xcconfig`)
      config_file_path = project_configuration.base_configuration_reference.real_path
      if File.exist? config_file_path
        # 排除xcconfig中的SEARCH_PATHS
        project_xcconfig = File.read(config_file_path).lines.reject{|line|line.include? "_SEARCH_PATHS"}.sort.join("")
      end
    end

    # target的build setting
    target_configuration = target.build_configurations.detect { | config | config.name == configuration_name}
    target_configuration_content = target_configuration.pretty_print.to_yaml

    #查找target的xcconfig文件
    target_xcconfig = ""
    if target_configuration.base_configuration_reference
      #Users/styf/Downloads/ruby_app/ZabelTest/ZabelAPP/Pods/Target Support Files/AFNetworking/AFNetworking.debug.xcconfig
      config_file_path = target_configuration.base_configuration_reference.real_path
      if File.exist? config_file_path
        # 排除xcconfig中的SEARCH_PATHS
        target_xcconfig = File.read(config_file_path).lines.reject{|line|line.include? "_SEARCH_PATHS"}.sort.join("")
      end
    end
    #单个文件的编译配置
    # Files settings :
    # NSObject+YYAddForARC.m
    # ---
    # COMPILER_FLAGS: "-fno-objc-arc"
    #
    # NSThread+YYAdd.m
    # ---
    # COMPILER_FLAGS: "-fno-objc-arc"
    first_configuration = []
    build_phases = []
    build_phases.push target.source_build_phase if target.methods.include? :source_build_phase  #PBXSourcesBuildPhase
    build_phases.push target.resources_build_phase if target.methods.include? :resources_build_phase #ResourcesBuildPhase
    build_phases.each do | build_phase |
      #这里我是有疑问的
      target.source_build_phase.files_references.each do | files_reference |
        files_reference.build_files.each do |build_file|
          if build_file.settings and build_file.settings.class == Hash
            first_configuration.push File.basename(build_file.file_ref.real_path.to_s) + "\n" + build_file.settings.to_yaml
          end
        end
      end
    end
    first_configuration_content = first_configuration.sort.uniq.join("\n")
    #传入的参数里有没有指定一些关键参数
    key_argv = []
    # bundle exec zabel xcodebuild -workspace ZabelAPP.xcworkspace -configuration Debug -scheme ZabelAPP -sdk iphoneos -arch arm64
    #
    # TODO: to add more and test more
    # However, you can control your cache keys manually by using pre and post.
    # ⚠️在xcode中，我没有这些参数，待研究有xcode中有哪些环境变量变化会需要让md5改变
    #
    # temp_path_list = ["-derivedDataPath", "-archivePath", "--derived_data_path", "--archive_path", "--build_path"] #跳过这些参数
    # argv.each_with_index do | arg, index |
    #     next if temp_path_list.include? arg
    #     next if index > 0 and temp_path_list.include? argv[index-1]
    #     next if arg.start_with? "DSTROOT="
    #     next if arg.start_with? "OBJROOT="
    #     next if arg.start_with? "SYMROOT="
    #     key_argv.push arg
    # end

    source_md5_list = []
    # zabel built-in verison, which will be changed for incompatibility in the future
    source_md5_list.push "Localpodbinary version : #{CocoapodsLocalpodbinary::VERSION}"
    # bundle exec zabel xcodebuild -workspace ZabelAPP.xcworkspace -configuration Debug -scheme ZabelAPP -sdk iphoneos -arch arm64
    #ARGV : ["xcodebuild", "-workspace", "ZabelAPP.xcworkspace", "-configuration", "Debug", "-scheme", "ZabelAPP", "-sdk", "iphoneos", "-arch", "arm64"]
    source_md5_list.push "ARGV : #{key_argv.to_s}"


    # 1.0.4------------start 改进了查找spec名称的方式
    # TODO: to get a explicit spec name from a target.
    target_possible_spec_names = []
    target_possible_spec_names.push target_configuration.build_settings["PRODUCT_NAME"] if target_configuration.build_settings["PRODUCT_NAME"]
    target_possible_spec_names.push target_configuration.build_settings["IBSC_MODULE"] if target_configuration.build_settings["IBSC_MODULE"]
    target_possible_spec_names.push File.basename(target_configuration.build_settings["CONFIGURATION_BUILD_DIR"]) if target_configuration.build_settings["CONFIGURATION_BUILD_DIR"]
    # 从xcconfig中的CONFIGURATION_BUILD_DIR和PODS_TARGET_SRCROOT，找可能的spec名称
    if target_xcconfig.lines.detect { | line | line.start_with? "CONFIGURATION_BUILD_DIR = "}
      target_possible_spec_names.push File.basename(target_xcconfig.lines.detect { | line | line.start_with? "CONFIGURATION_BUILD_DIR = "}.strip)
    end
    if target_xcconfig.lines.detect { | line | line.start_with? "PODS_TARGET_SRCROOT = "}
      target_possible_spec_names.push File.basename(target_xcconfig.lines.detect { | line | line.start_with? "PODS_TARGET_SRCROOT = "}.strip)
    end

    target_match_spec_names = []
    target_possible_spec_names.uniq.sort.each do | spec_name |
      if spec_name.size > 0 and $lpb_podfile_spec_checksums.has_key? spec_name
        source_md5_list.push "SPEC CHECKSUM : #{spec_name} #{$lpb_podfile_spec_checksums[spec_name]}"
        target_match_spec_names.push spec_name
      end
    end

    unless target_match_spec_names.size == 1
      puts "[LPB/E] #{target.name} #{target_possible_spec_names.to_s} #{target_match_spec_names.to_s} SPEC CHECKSUM should be found"
      puts target_configuration.build_settings.to_s
      puts target_xcconfig
    end
    # 1.0.4------------end

    source_md5_list.push "Project : #{File.basename(project.path)}"
    source_md5_list.push "Project configuration : "
    source_md5_list.push project_configuration_content.strip
    source_md5_list.push "Project xcconfig : "
    source_md5_list.push project_xcconfig.strip
    source_md5_list.push "Target : #{target.name}"
    source_md5_list.push "Target type : #{target.product_type}"
    source_md5_list.push "Target configuration : "
    source_md5_list.push target_configuration_content.strip
    source_md5_list.push "Target xcconfig : "
    source_md5_list.push target_xcconfig.strip
    source_md5_list.push "Files settings : "
    source_md5_list.push first_configuration_content.strip

    source_md5_list.push "Files MD5 : "
    source_files.uniq.sort.each do | file |
      source_md5_list.push lpb_get_content_without_pwd(file) + " : " + lpb_get_file_md5(file)
    end

    source_md5_content = source_md5_list.join("\n")
    return source_md5_content
  end

  # rm -rf Pods/*.xcodeproj/project.localpodbinary_backup_pbxproj
  # rm -rf Pods/*.xcodeproj/*.localpodbinary_target_context.yml
  def self.lpb_clean_temp_files
    command = "rm -rf Pods/*.xcodeproj/project.localpodbinary_backup_pbxproj"
    puts command
    raise unless system command

    command = "rm -rf Pods/*.xcodeproj/*.#{FILE_NAME_TARGET_CONTEXT}"
    puts command
    raise unless system command
  end

  # 增加一个缓存
  # 打压缩包，建缓存文件夹，写入两个文件
  def self.lpb_add_cache(target, target_context, message)
    target_md5 = target_context[:target_md5]
    # CONFIGURATION_BUILD_DIR\=/Users/styf/Library/Developer/Xcode/DerivedData/LocalCacheAPP-ezyfamlzjecangaabdcjoovrrlot/Build/Products/Debug-iphoneos/WPTAllSeeingEyeModule
    product_dir = target_context[BUILD_KEY_CONFIGURATION_BUILD_DIR]
    # TARGET_TEMP_DIR\=/Users/styf/Library/Developer/Xcode/DerivedData/LocalCacheAPP-ezyfamlzjecangaabdcjoovrrlot/Build/Intermediates.noindex/WPTAllSeeingEyeModule.build/Debug-iphoneos/WPTAllSeeingEyeModule-WPTAESBundle.build
    intermediate_dir = target_context[BUILD_KEY_TARGET_TEMP_DIR]
    # FULL_PRODUCT_NAME\=WPTAESBundle.bundle
    full_product_name = target_context[BUILD_KEY_FULL_PRODUCT_NAME]

    target_cache_dir = lpb_get_cache_root + "/" + target.name + "-" + target_md5 + "-" + (Time.now.to_f * 1000).to_i.to_s

    Dir.glob("#{product_dir}/**/*.modulemap").each do | modulemap |
      modulemap_content = File.read(modulemap)
      if modulemap_content.include? File.dirname(modulemap) + "/"
        modulemap_content = modulemap_content.gsub(File.dirname(modulemap) + "/", "")
        File.write(modulemap, modulemap_content)
      end
    end
    #检查库是否存在
    unless full_product_name and full_product_name.size > 0 and File.exist? "#{product_dir}/#{full_product_name}"
      puts "[LPB/E] #{target.name} #{product_dir}/#{full_product_name} should exist"
      return false
    end

    zip_start_time = Time.now

    #不压缩只移动---------
    if File.exist? target_cache_dir
      puts "[LPB/E] #{target_cache_dir} should not exist"
      raise unless system "rm -rf \"#{target_cache_dir}\""
      return false
    end

    command = "mkdir -p \"#{target_cache_dir}\""
    unless system command
      puts command
      puts "[LPB/E] #{command} should succeed"
      return false
    end

    cache_product_path = target_cache_dir + "/#{full_product_name}"
    command = "mv \"#{product_dir}/#{full_product_name}\" \"#{cache_product_path}\""
    puts "[LPB/I] 从编译目录拷贝到缓存目录 #{command}"
    unless system command
      puts command
      puts "[LPB/E] #{command} should succeed"
      return false
    end
    unless File.exist? cache_product_path
      puts "[LPB/E] #{cache_product_path} should exist after mv"
      return false
    end

    #bundle和framework类型是文件夹，无法计算md5值，压缩一个文件出来，仅用于md5比对   com.apple.product-type.bundle
    if target.product_type == "com.apple.product-type.bundle" or target.product_type == "com.apple.product-type.framework"
      command = "cd \"#{target_cache_dir}\" && tar -L -c -f #{FILE_NAME_PRODUCT} #{full_product_name}"
      puts "[LPB/I] bundle类型压缩一下 #{command}"
      unless system command
        puts "[LPB/E] #{command} should succeed"
        return false
      end
      cache_product_path = target_cache_dir + "/#{FILE_NAME_PRODUCT}"
    end
    #不压缩只移动---------

    target_context[:product_md5] = lpb_get_file_md5(cache_product_path)
    target_context[:build_product_dir] = target_context[BUILD_KEY_CONFIGURATION_BUILD_DIR].gsub(target_context[BUILD_KEY_SYMROOT] + "/", "")
    target_context[:build_intermediate_dir] = target_context[BUILD_KEY_TARGET_TEMP_DIR].gsub(target_context[BUILD_KEY_OBJROOT] + "/", "")
    if target_context[BUILD_KEY_MODULEMAP_FILE]
      target_context[BUILD_KEY_MODULEMAP_FILE] = lpb_get_content_without_pwd target_context[BUILD_KEY_MODULEMAP_FILE]
    end

    target_context = target_context.clone
    target_context.delete(:dependency_files)
    target_context.delete(:target_status)
    target_context.delete(:potential_hit_target_cache_dirs)
    target_context.delete(:target_md5_content)
    target_context.delete(:miss_dependency_list)
    target_context.delete(:source_files)
    [BUILD_KEY_SYMROOT, BUILD_KEY_CONFIGURATION_BUILD_DIR, BUILD_KEY_OBJROOT, BUILD_KEY_TARGET_TEMP_DIR, BUILD_KEY_PODS_XCFRAMEWORKS_BUILD_DIR, BUILD_KEY_SRCROOT].each do | key |
      target_context.delete(key)
    end
    #写入到两个文件中
    File.write(target_cache_dir + "/" + FILE_NAME_CONTEXT, target_context.to_yaml)
    File.write(target_cache_dir + "/" + FILE_NAME_MESSAGE, message)

    return true
  end

  #检查是否有缓存命中，命中则返回缓存文件夹
  # 检查依赖是否存在、匹配，检查target_md5和product_md5
  # 1.0.4新增 miss_dependency_list
  def self.lpb_get_potential_hit_target_cache_dirs(target, target_md5,miss_dependency_list)
    dependency_start_time = Time.now
    target_cache_dirs = Dir.glob(lpb_get_cache_root + "/" + target.name + "-" + target_md5 + "-*")
    # 缓存路径：["/Users/styf/zabel/AFNetworking-76658271cc8f3a683609e0b97fdb46ba-1628834493476"]
    # puts "缓存路径：#{target_cache_dirs}"
    file_time_hash = {}
    target_cache_dirs.each do | file |
      file_time_hash[file] = File.mtime(file) #文件最后修改时间
    end
    target_cache_dirs = target_cache_dirs.sort_by {|file| - file_time_hash[file].to_f}
    potential_hit_target_cache_dirs = []
    target_cache_dirs.each do | target_cache_dir |
      next unless File.exist? target_cache_dir + "/" + FILE_NAME_CONTEXT
      target_context = YAML.load(File.read(target_cache_dir + "/" + FILE_NAME_CONTEXT))
      full_product_name = target_context[BUILD_KEY_FULL_PRODUCT_NAME]
      next unless File.exist? target_cache_dir + "/" + full_product_name

      dependency_miss = false
      #依赖的文件是否存在、md5是否匹配
      target_context[:dependency_files_md5].each do | item |
        # :dependency_files_md5:
        #   - - "/Applications/Xcode.app/Contents/Developer/Platforms/iPhoneOS.platform/Developer/SDKs/iPhoneOS14.4.sdk/usr/include/mach-o/compact_unwind_encoding.modulemap"
        # - 4fc4584f1635db68faed384879bba717
        # - - "/Applications/Xcode.app/Contents/Developer/Platforms/iPhoneOS.platform/Developer/SDKs/iPhoneOS14.4.sdk/usr/include/mach-o/dyld.modulemap"
        # - ad26e820336bf60c1262d2341d984623
        # - - Pods/Target Support Files/SDWebImage/SDWebImage-prefix.pch
        # - eeceba9fd714fe0bcc4ba17da85b55a7
        dependency_file = item[0]
        dependency_md5 = item[1]
        unless File.exist? dependency_file
          puts "[LPB/W] #{target.name} #{dependency_file} file should exist to be hit"
          #1.0.4新增
          miss_dependency_list.push "[LPB/W] #{target.name} #{dependency_file} file should exist to be hit"
          dependency_miss = true
          break
        end
        unless lpb_get_file_md5(dependency_file) == dependency_md5
          puts "[LPB/W] #{target.name} #{dependency_file} md5 should match to be hit"
          #1.0.4新增
          miss_dependency_list.push "[LPB/W] #{target.name} #{dependency_file} md5 #{lpb_get_file_md5(dependency_file)} should match #{dependency_md5} to be hit"
          dependency_miss = true
          break
        end
      end

      #依赖文件存在，且md5也正确
      if not dependency_miss
        #校验target_md5
        if not target_context[:target_md5] == target_md5
          command = "rm -rf \"#{target_cache_dir}\""
          raise unless system command
          puts "[LPB/E] #{target.name} #{target_cache_dir} target md5 should match to be verified"
          dependency_miss = false
          next
        end
        #校验product_md5     product.tar的md5
        product_md5_path = target_cache_dir + "/" + target_context[BUILD_KEY_FULL_PRODUCT_NAME]
        if target.product_type == "com.apple.product-type.bundle" or target.product_type == "com.apple.product-type.framework" #bundle和framework的md5是用它的压缩包计算的
          product_md5_path = target_cache_dir + "/" + FILE_NAME_PRODUCT
        end

        if not target_context[:product_md5] == lpb_get_file_md5(product_md5_path)
          command = "rm -rf \"#{target_cache_dir}\""
          raise unless system command
          puts "[LPB/E] #{target.name} #{target_cache_dir} product md5 should match to be verified"
          dependency_miss = false
          next
        end

        potential_hit_target_cache_dirs.push target_cache_dir
        if target_context[:dependency_targets_md5].size == 0
          break
        end
        if potential_hit_target_cache_dirs.size > 10
          break
        end
      end
    end
    return potential_hit_target_cache_dirs
  end

  def self.printenv
    #export PROJECT_FILE_PATH\=/Users/styf/Downloads/ruby_app/ZabelTest/ZabelAPP/Pods/SDWebImage.xcodeproj
    project_path = ENV["PROJECT_FILE_PATH"]
    #export TARGETNAME\=SDWebImage
    target_name = ENV["TARGETNAME"]

    target_context = YAML.load(File.read("#{project_path}/#{target_name}.#{FILE_NAME_TARGET_CONTEXT}"))

    # see https://developer.apple.com/library/archive/documentation/DeveloperTools/Reference/XcodeBuildSettingRef/1-Build_Setting_Reference/build_setting_ref.html
    [BUILD_KEY_SYMROOT, BUILD_KEY_CONFIGURATION_BUILD_DIR, BUILD_KEY_OBJROOT, BUILD_KEY_TARGET_TEMP_DIR, BUILD_KEY_PODS_XCFRAMEWORKS_BUILD_DIR, BUILD_KEY_MODULEMAP_FILE, BUILD_KEY_SRCROOT, BUILD_KEY_FULL_PRODUCT_NAME].sort.each do | key |
      if ENV[key]
        target_context[key] = ENV[key]
      end
    end
    File.write("#{project_path}/#{target_name}.#{FILE_NAME_TARGET_CONTEXT}", target_context.to_yaml)
    puts "#{target_name}环境变量写入结束"
  end

  #插入获取编译环境变量新脚本  localBinary_pod_printenv
  def self.lpb_inject_localBinary_pod_printenv(target)
    execshell = "\"${SRCROOT}/../cocoapods-localpodbinary/shell/LocalPodBinary_PrintENV.sh\""
    inject_phase = target.new_shell_script_build_phase("localpodbinary_printenv_#{target.name}")
    inject_phase.shell_script = "#{execshell}"
    inject_phase.show_env_vars_in_log = '1'
  end

  #给主工程插入生产脚本脚本  localBinary_produce
  def self.lpb_inject_localBinary_main_produce(main_target)
    execshell = "cd \"${SRCROOT}\" && \"cocoapods-localpodbinary/shell/LocalPodBinary_Produce.sh\""
    #这个脚本在执行里会相对主工程的xcodeproj文件路径去找，如果xcodeproj文件是一级目录的，记得要做调整
    main_xcodeproj_path_array = Dir.glob("*.xcodeproj")#看看主工程是不是在一级目录
    if main_xcodeproj_path_array.size == 0
      execshell = "cd \"${SRCROOT}/..\" && \"cocoapods-localpodbinary/shell/LocalPodBinary_Produce.sh\""
    end

    inject_phase = main_target.new_shell_script_build_phase(PRODUCE_SHELL_NAME)
    inject_phase.shell_script = "#{execshell}"
    inject_phase.show_env_vars_in_log = '1'
    puts "[LPB/I] 插入主工程生产脚本"
  end

  # 消费阶段
  def self.consume

    # 只在debug模式下生效
    configuration_name = "Debug"

    start_time = Time.now

    #拿到主工程对象
    main_project = lpb_get_main_project
    main_project_name = File.basename(main_project.path).split(".")[0]
    unless main_project
      puts "[LPB/E] 主工程未找到"
      return
    end

    #拿到和主工程同名的target
    main_target = lpb_get_main_target(main_project,main_project_name)
    unless main_target
      puts "[LPB/E] 主target未找到"
      return
    end

    #拿到主target的xcconfig
    main_target_configuration = main_target.build_configurations.detect { | config | config.name == configuration_name}
    main_target_xcconfig = "" #主工程xcconfig的内容
    main_target_xcconfig_path = "" #主工程xcconfig的路径
    if main_target_configuration.base_configuration_reference
      main_target_xcconfig_path = main_target_configuration.base_configuration_reference.real_path
      if File.exist? main_target_xcconfig_path
        main_target_xcconfig = File.read(main_target_xcconfig_path)
      else
        puts "[LPB/E] 没有找到主项目的xcconfig文件：#{config_file_path}"
        return
      end
    end

    #拿到主工程的pod资源处理脚本
    pod_resources_shell_path = "Pods/Target Support Files/Pods-#{main_project_name}/Pods-#{main_project_name}-resources.sh"
    pod_resources_shell = "" #pod资源脚本内容
    if File.exist? pod_resources_shell_path
      pod_resources_shell = File.read(pod_resources_shell_path)
    else
      puts "[LPB/E] pod资源脚本不存在：#{pod_resources_shell_path}"
      return
    end
    puts "[LBP/I] 已找到主工程的xccofig和pod资源脚本"

    #删除主target的生产脚本
    lpb_delete_main_target_produce_shell(main_project,main_target)

    #删除临时工程文件
    lpb_clean_temp_files
    puts "[LPB/I] 删除所有Pod工程的备份工程和上下文文件完毕"

    #拿到所有xcodeproj工程对象
    projects = lpb_get_projects

    pre_targets_context = {}

    hit_count = 0
    miss_count = 0
    hit_target_md5_cache_set = Set.new
    iteration_count = 0
    # Pods-XXXX
    pod_target = nil

    projects.each do | project |
      #1.0.4新增
      project_configuration = project.build_configurations.detect { | config | config.name == configuration_name}
      unless project_configuration
        puts "[LPB/E] #{project.path} should have config #{configuration_name}"
        next
      end

      project.native_targets.each do | target |
        if target.name.start_with? "Pods-"
          pod_target = target
        end
        #target能否缓存
        if lpb_can_cache_target(target)  #排除了Pods-XXX 和手动配置不需要使用缓存的库
          #收集编译文件、头文件、资源文件的路径
          source_files = lpb_get_target_source_files(target)
          next unless source_files.size >= lpb_get_min_source_file_count
          argv = {}
          target_md5_content = lpb_get_target_md5_content(project, target, configuration_name, argv, source_files)
          #对整个target和编译参数、文件md5进行md5化
          target_md5 = Digest::MD5.hexdigest(target_md5_content)
          #如果命中缓存则返回缓存所在目录
          miss_dependency_list = []
          potential_hit_target_cache_dirs = lpb_get_potential_hit_target_cache_dirs(target, target_md5,miss_dependency_list)

          target_context = {}
          target_context[:target_md5] = target_md5
          target_context[:potential_hit_target_cache_dirs] = potential_hit_target_cache_dirs
          target_context[:miss_dependency_list] = miss_dependency_list
          target_context[:target_md5_content] = target_md5_content
          target_context[:source_files] = source_files
          if potential_hit_target_cache_dirs.size == 0
            # 1.0.4打印缺少的依赖
            if miss_dependency_list.size > 0
              puts miss_dependency_list.uniq.join("\n")
            end
            puts "[LPB/I] miss #{target.name} #{target_md5} in iteration #{iteration_count}"
            target_context[:target_status] = STATUS_MISS
            miss_count = miss_count + 1
          end
          pre_targets_context[target] = target_context
        end
      end
    end

    while true
      iteration_count = iteration_count + 1
      #已确认的数量
      confirm_count = hit_count + miss_count
      projects.each do | project |
        project.native_targets.each do | target |
          next unless pre_targets_context.has_key? target
          target_context = pre_targets_context[target]
          next if target_context[:target_status] == STATUS_MISS
          next if target_context[:target_status] == STATUS_HIT
          potential_hit_target_cache_dirs = target_context[:potential_hit_target_cache_dirs]
          next if potential_hit_target_cache_dirs.size == 0
          hit_target_cache_dir = nil
          potential_hit_target_cache_dirs.each do | target_cache_dir |
            next unless File.exist? target_cache_dir + "/" + FILE_NAME_CONTEXT
            #这是缓存文件夹里的上下文信息
            hit_target_context = YAML.load(File.read(target_cache_dir + "/" + FILE_NAME_CONTEXT))
            hit_target_cache_dir = target_cache_dir
            # 有没有依赖其他targets
            hit_target_context[:dependency_targets_md5].each do | item |
              dependency_target = item[0]
              dependency_target_md5 = item[1]

              # cycle dependency targets will be miss every time.
              # TODO: to detect cycle dependency so that cache will not be added,
              # or to hit cache together with some kind of algorithms.

              # 这个库依赖的target 还没命中，直接跳出 ，本库也不命中 。等依赖的库处理完了，再来处理这个库
              # 如果本库未处理，但是依赖的库是Miss呢？hit_target_md5_cache_set也没有，还是会把hit_target_cache_dir设为空，死循环了？
              # 能进到这里的，都是有缓存文件夹的，说明本库是有缓存过的，依赖库会MISS，说明依赖库被手动删了
              unless hit_target_md5_cache_set.include? "#{dependency_target}-#{dependency_target_md5}"
                hit_target_cache_dir = nil
                break
              end
            end
            if hit_target_cache_dir
              target_context = target_context.merge!(hit_target_context)
              break
            end
          end
          #命中缓存了
          if hit_target_cache_dir
            puts "[LPB/I] hit #{target.name} #{target_context[:target_md5]} in iteration #{iteration_count} potential #{potential_hit_target_cache_dirs.size}"
            target_context[:target_status] = STATUS_HIT
            target_context[:hit_target_cache_dir] = hit_target_cache_dir
            hit_count = hit_count + 1
            hit_target_md5_cache_set.add "#{target.name}-#{target_context[:target_md5]}"
          end
        end
      end

      if hit_count + miss_count == confirm_count
        #循环一遍下来，已确认数量没有变化，跳出
        break
      end
    end

    #到这里pre_targets_context中的上下文都处理过了
    projects.each do | project |
      should_save = false
      project.native_targets.each do | target |
        next unless pre_targets_context.has_key? target
        target_context = pre_targets_context[target]

        if target_context[:target_status] == STATUS_HIT
          target_cache_dir = target_context[:hit_target_cache_dir]

          # touch to update mtime
          raise unless system "touch \"#{target_cache_dir}\""

          # delete build phases to disable build command
          target.build_phases.delete_if { | build_phase |
            # puts "#{build_phase}"
            # HeadersBuildPhase
            # SourcesBuildPhase
            # FrameworksBuildPhase
            # ResourcesBuildPhase
            build_phase.class == Xcodeproj::Project::Object::PBXHeadersBuildPhase or
              build_phase.class == Xcodeproj::Project::Object::PBXSourcesBuildPhase or
              build_phase.class == Xcodeproj::Project::Object::PBXResourcesBuildPhase
          }

          if target.product_type == "com.apple.product-type.bundle"
            # 2 修改 Pods-XXXX-resource.sh 脚本
            #  install_resource "${PODS_CONFIGURATION_BUILD_DIR}/WPTAllSeeingEyeModule/WPTAESBundle.bundle"
            #  bundle的target名称 WPTAllSeeingEyeModule-WPTAESBundle  拆分一下

            bundle_target_name = target.name.split("-")[0]
            pod_resources_shell = pod_resources_shell.gsub("${PODS_CONFIGURATION_BUILD_DIR}/#{bundle_target_name}", target_cache_dir)
            File.write(pod_resources_shell_path, pod_resources_shell)
            puts "[LPB/I] #{target.name} 修改pod脚本文件"
          else
            # PODS_CONFIGURATION_BUILD_DIR\=/Users/styf/Library/Developer/Xcode/DerivedData/LocalCacheAPP-ezyfamlzjecangaabdcjoovrrlot/Build/Products/Debug-iphoneos
            # PODS_CONFIGURATION_BUILD_DIR=${PODS_BUILD_DIR}/$(CONFIGURATION)$(EFFECTIVE_PLATFORM_NAME)
            # PODS_BUILD_DIR = BUILD_DIR\=/Users/styf/Library/Developer/Xcode/DerivedData/LocalCacheAPP-ezyfamlzjecangaabdcjoovrrlot/Build/Products
            #
            # 1 修改主项目的xcconfig
            # 1.1 FRAMEWORK_SEARCH_PATHS----目录是PODS_CONFIGURATION_BUILD_DIR的指向缓存下的framework
            # "${PODS_CONFIGURATION_BUILD_DIR}/WPTDataTracker"
            # 1.2 HEADER_SEARCH_PATHS----.a的库可以不管，主要是framework的库需要指向缓存下的framework
            # "${PODS_CONFIGURATION_BUILD_DIR}/WPTDataTracker/WPTDataTracker.framework/Headers"
            # 1.3 LIBRARY_SEARCH_PATHS----处理目录是PODS_CONFIGURATION_BUILD_DIR的.a
            # "${PODS_CONFIGURATION_BUILD_DIR}/AFNetworking"
            # 1.4 OTHER_CFLAGS----看到了目录是PODS_CONFIGURATION_BUILD_DIR的，应该要处理
            # -iframework "${PODS_CONFIGURATION_BUILD_DIR}/WPTDataTracker"
            # 1.5 OTHER_LDFLAGS----看到了一个特殊情况,有库配置PODS_CONFIGURATION_BUILD_DIR
            # -force_load ${PODS_CONFIGURATION_BUILD_DIR}/WPTDataTracker/WPTDataTracker.framework/WPTDataTracker
            #
            # ⚠️小心近似名称的库
            #
            # "/Users/styf/localPodBinary/SDWebImage-b4deaf3e64d98f94171b9054a033682f-1629968158141"
            # "/Users/styf/localPodBinary/SDWebImageWebPCoder-9dc98b8869b80589e8a18cd4b9c4ac04-1629968158231"

            main_target_xcconfig = main_target_xcconfig.gsub("\"${PODS_CONFIGURATION_BUILD_DIR}/#{target.name}\"", "\"#{target_cache_dir}\"")
            main_target_xcconfig = main_target_xcconfig.gsub("${PODS_CONFIGURATION_BUILD_DIR}/#{target.name}/", "#{target_cache_dir}/")
            File.write(main_target_xcconfig_path, main_target_xcconfig)
            puts "[LPB/I] #{target.name} 修改主工程xcconfig文件"
          end

        else
          unless target_context[:target_status] == STATUS_MISS
            #循环依赖的库直接当做Miss
            target_context[:target_status] = STATUS_MISS
            #打印缺失依赖项
            miss_dependency_list = target_context[:miss_dependency_list]
            if miss_dependency_list.size > 0
              puts miss_dependency_list.uniq.join("\n")
            end
            puts "[LBP/I] miss #{target.name} #{target_context[:target_md5]} in iteration #{iteration_count}"
            miss_count = miss_count + 1
          end
          # 插入新脚本 printenv 拿到环境变量
          lpb_inject_localBinary_pod_printenv(target)

          # 写入上下文信息到文件 给生产阶段用
          File.write("#{project.path}/#{target.name}.#{FILE_NAME_TARGET_CONTEXT}", target_context.to_yaml)
          #复制一份作为备份工程
          lpb_backup_project(project)
        end
        should_save = true
      end
      if should_save
        project.save
      end
    end

    if miss_count > 0
      # 主工程插入生产脚本produce
      lpb_inject_localBinary_main_produce(main_target)
      main_project.save
    end

    puts "[LBP/I] total #{hit_count + miss_count} hit #{hit_count} miss #{miss_count} iteration #{iteration_count}"

    puts "[LBP/I] duration = #{(Time.now - start_time).to_i} s in stage pre"
  end

  # 这个脚本在Xcode编译完成后执行  生产阶段
  def self.produce
    #检查缓存是否存在
    configuration_name = nil

    if ENV[BUILD_KEY_CONFIGURATION]
      configuration_name = ENV[BUILD_KEY_CONFIGURATION]
    end
    unless configuration_name and configuration_name.size > 0
      raise "[LPB/E] -configuration or --configuration should be set"
    end
    # 非debug环境下不生产
    return unless configuration_name == "Debug"

    start_time = Time.now
    #有没有设置LPB_CLEAR_ALL，有则清理缓存文件夹
    if ENV["LPB_CLEAR_ALL"] == "YES"
      command = "rm -rf \"#{lpb_get_cache_root}\""
      puts command
      raise unless system command
    end

    #拿到主工程对象
    main_project = lpb_get_main_project
    main_project_name = File.basename(main_project.path).split(".")[0]
    unless main_project
      puts "[LPB/E] 主工程未找到"
      return
    end

    #拿到和主工程同名的target
    main_target = lpb_get_main_target(main_project,main_project_name)
    unless main_target
      puts "[LPB/E] 主target未找到"
      return
    end

    add_count = 0
    #拿到所有xcodeproj工程对象
    projects = lpb_get_projects

    pre_targets_context = {}

    hit_count = 0
    miss_count = 0
    hit_target_md5_cache_set = Set.new
    iteration_count = 0

    projects.each do | project |
      #1.0.4新增
      project_configuration = project.build_configurations.detect { | config | config.name == configuration_name}
      unless project_configuration
        puts "[LPB/E] #{project.path} should have config #{configuration_name}"
        next
      end

      project.native_targets.each do | target |
        target_context_file = "#{project.path}/#{target.name}.#{FILE_NAME_TARGET_CONTEXT}"
        unless File.exist? target_context_file #缺少上下文文件就跳过  命中缓存的库没有上下文文件
          next
        end
        #target能否缓存
        if lpb_can_cache_target(target)  #排除了Pods-XXX 和 手动配置不需要缓存的库
          target_context = YAML.load(File.read(target_context_file))
          #puts "看看库状态#{target_context[:target_status]}"
          if target_context[:target_status] == STATUS_MISS
            #对于miss的库，补充target_context的信息

            # 收集编译文件、头文件、资源文件的路径
            source_files = target_context[:source_files]
            # miss的工程 会在 printenv中把环境变量写入
            product_dir = target_context[BUILD_KEY_CONFIGURATION_BUILD_DIR]
            intermediate_dir = target_context[BUILD_KEY_TARGET_TEMP_DIR]
            xcframeworks_build_dir = target_context[BUILD_KEY_PODS_XCFRAMEWORKS_BUILD_DIR]
            # 从编译产物.d文件中获取所有依赖文件路径
            dependency_files = lpb_get_dependency_files(target, intermediate_dir, product_dir, xcframeworks_build_dir)
            if source_files.size > 0 and dependency_files.size == 0 and target.product_type != "com.apple.product-type.bundle"
              puts "[LPB/E] #{target.name} should have dependent files"
              next
            end
            # 取差集，剩余的是依赖其他库的文件
            target_context[:dependency_files] = dependency_files - source_files
            # 获取工程信息用于生成库的md5

            argv = {}
            # 再次生成md5值是为了校验
            target_md5_content = lpb_get_target_md5_content(project, target, configuration_name, argv, source_files)
            target_context[:target_md5_content] = target_md5_content
            target_md5 = Digest::MD5.hexdigest(target_md5_content)
            unless target_context[:target_md5] == target_md5
              puts "[LPB/E] #{target.name} md5 should not be changed after build"
              next
            end
            # 支持modulemap
            if target_context[BUILD_KEY_SRCROOT] and target_context[BUILD_KEY_SRCROOT].size > 0 and
              target_context[BUILD_KEY_MODULEMAP_FILE] and target_context[BUILD_KEY_MODULEMAP_FILE].size > 0
              if File.exist? Dir.pwd + "/" + lpb_get_content_without_pwd("#{target_context[BUILD_KEY_SRCROOT]}/#{target_context[BUILD_KEY_MODULEMAP_FILE]}")
                target_context[BUILD_KEY_MODULEMAP_FILE] = lpb_get_content_without_pwd("#{target_context[BUILD_KEY_SRCROOT]}/#{target_context[BUILD_KEY_MODULEMAP_FILE]}")
              else
                puts "[LPB/E] #{target.name} #{target_context[BUILD_KEY_MODULEMAP_FILE]} should be supported"
                next
              end
            end
          elsif target_context[:target_status] == STATUS_HIT
            # 这个命中缓存的库有问题，下面依赖这个库的库将不缓存
            # 支持modulemap
            if target_context[BUILD_KEY_MODULEMAP_FILE] and target_context[BUILD_KEY_MODULEMAP_FILE].size > 0
              if not File.exist? Dir.pwd + "/" + target_context[BUILD_KEY_MODULEMAP_FILE]
                puts "[LPB/E] #{target.name} #{target_context[BUILD_KEY_MODULEMAP_FILE]} should be supported"
                next
              end
            end
          else
            puts "[LPB/E] #{target.name} should be hit or miss"
            next
          end

          pre_targets_context[target] = target_context
        end
      end
    end

    #处理miss的库
    projects.each do | project |
      need_restore = false
      project.native_targets.each do | target |
        if pre_targets_context.has_key? target
          target_context = pre_targets_context[target]
          next unless target_context[:target_status] == STATUS_MISS
          #处理miss的库
          dependency_targets_set = Set.new
          implicit_dependencies = []
          need_restore = true

          pre_targets_context.each do | other_target, other_target_context |
            next if other_target == target

            next if target.product_type == "com.apple.product-type.bundle"
            next if other_target.product_type == "com.apple.product-type.bundle"
            # 找到本库依赖的哪些其他库
            target_context[:dependency_files].each do | dependency |

              if other_target_context[BUILD_KEY_CONFIGURATION_BUILD_DIR] and other_target_context[BUILD_KEY_CONFIGURATION_BUILD_DIR].size > 0 and
                dependency.start_with? other_target_context[BUILD_KEY_CONFIGURATION_BUILD_DIR] + "/"
                dependency_targets_set.add other_target
                implicit_dependencies.push dependency
              elsif other_target_context[BUILD_KEY_TARGET_TEMP_DIR] and other_target_context[BUILD_KEY_TARGET_TEMP_DIR].size > 0 and
                dependency.start_with? other_target_context[BUILD_KEY_TARGET_TEMP_DIR] + "/"
                dependency_targets_set.add other_target
                implicit_dependencies.push dependency
              elsif other_target_context[:build_product_dir] and other_target_context[:build_product_dir].size > 0 and
                dependency.start_with? target_context[BUILD_KEY_SYMROOT] + "/" + other_target_context[:build_product_dir] + "/"
                dependency_targets_set.add other_target
                implicit_dependencies.push dependency
              elsif other_target_context[:build_intermediate_dir] and other_target_context[:build_intermediate_dir].size > 0 and
                dependency.start_with? target_context[BUILD_KEY_OBJROOT] + "/" + other_target_context[:build_intermediate_dir] + "/"
                dependency_targets_set.add other_target
                implicit_dependencies.push dependency
              end

              unless lpb_should_not_detect_module_map_dependency
                if other_target_context[BUILD_KEY_MODULEMAP_FILE] and other_target_context[BUILD_KEY_MODULEMAP_FILE].size > 0 and
                  dependency == Dir.pwd + "/" + other_target_context[BUILD_KEY_MODULEMAP_FILE]
                  dependency_targets_set.add other_target
                end
              end
            end

            target_context[:dependency_files] = target_context[:dependency_files] - implicit_dependencies

          end

          target_context[:dependency_files] = target_context[:dependency_files] - implicit_dependencies
          dependency_files_md5 = []
          # 1.0.4新增
          should_not_cache = false
          target_context[:dependency_files].each do | file |
            if file.start_with? target_context[BUILD_KEY_OBJROOT] + "/" or file.start_with? target_context[BUILD_KEY_SYMROOT] + "/"
              puts "[LPB/W] #{target.name} #{file} dependecy should not include build path"
              should_not_cache = true
              break
            end
            dependency_files_md5.push [lpb_get_content_without_pwd(file), lpb_get_file_md5(file)]
          end
          next if should_not_cache

          # 剩余的依赖文件 1.0.4调整
          target_context[:dependency_files_md5] = dependency_files_md5.sort.uniq
          # 依赖的其他库的信息
          dependency_targets_md5 = dependency_targets_set.to_a.map { | target |  [target.name, pre_targets_context[target][:target_md5]]}
          target_context[:dependency_targets_md5] = dependency_targets_md5

          message = target_context[:target_md5_content]
          # 新建一个缓存
          if lpb_add_cache(target, target_context, message)
            add_count = add_count + 1
            #删除上下文信息文件
            lpb_delete_target_context_file(project,target)
          end
        end
      end
      if need_restore
        #还原pod工程，因为插入过脚本
        puts "[LPB/I] 还原工程"
        lpb_restore_project(project)
      end
    end

    lpb_keep

    #删除主target的生产脚本
    lpb_delete_main_target_produce_shell(main_project,main_target)

    puts "[LPB/I] total add #{add_count}"

    puts "[LPB/I] duration = #{(Time.now - start_time).to_i} s in stage post"

  end

  def self.clean
    lpb_clean_temp_files
  end

end
