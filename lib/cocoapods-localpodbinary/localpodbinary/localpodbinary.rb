
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

  #??????????????????????????????
  def self.lpb_get_min_source_file_count
    # By default, localPodBinary caches targets which count of source files is greater than or equal 1.
    # You can set this value to 0 or more than 1 to achieve higher speed.
    min_source_file_count = ENV["LPB_MIN_SOURCE_FILE_COUNT"]
    if min_source_file_count and min_source_file_count.to_i.to_s == min_source_file_count
      return min_source_file_count.to_i
    end
    return 1
  end

  #????????????xcodeproj????????????
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

  #???????????????
  def self.lpb_get_main_project
    main_xcodeproj_path_array = Dir.glob("*.xcodeproj")
    if main_xcodeproj_path_array.size == 0
      # ???????????????????????????????????????????????????????????????????????????????????????????????????
      main_xcodeproj_path_array = Dir.glob("#{File.basename(Dir.pwd.to_s)}/*.xcodeproj")
    end
    if main_xcodeproj_path_array.size == 0
      puts "[LPB/E] ??????????????????"
      return
    end
    main_xcodeproj_path = main_xcodeproj_path_array[0]
    puts "[LPB/I] ??????????????????#{main_xcodeproj_path}"
    main_project = Xcodeproj::Project.open(main_xcodeproj_path)
    return main_project
  end

  #???????????????????????????target
  def self.lpb_get_main_target(main_project,main_project_name)
    main_target = nil

    main_project.native_targets.each do | target |
      if target.name == main_project_name #????????????????????????????????????????????????
        main_target = target
        break
      end
    end

    unless main_target
      puts "[LPB/E] ??????????????????target????????????"
    end
    return main_target
  end

  # ?????????target???????????????
  def self.lpb_delete_main_target_produce_shell(main_project,main_target)
    main_target.build_phases.delete_if { | build_phase |
      build_phase.class == Xcodeproj::Project::Object::PBXShellScriptBuildPhase and build_phase.name == PRODUCE_SHELL_NAME
    }
    main_project.save
    puts "[LPB/I] ???????????????????????????"
  end

  # ???Pods.xcodeproj???????????????????????????????????????????????????wrapper.pb-project
  # ??????????????????
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
  # target????????????   ???????????????????????????
  def self.lpb_can_cache_target(target)
    if target.name.start_with? "Pods-"
      puts "[LPB/I] skip #{target.name}"
      return false
    end

    # ?????????podfile????????? ???????????????????????????
    if $has_load_cache_file == false
      $has_load_cache_file = true
      cache_file_path = Dir.pwd + "/" + FILE_NAME_CACHE
      if File.exist? cache_file_path
        puts "[LPB/I] ???????????????podfile??????????????????"
        $cache_hash = YAML.load(File.read(cache_file_path))
      else
        puts "[LPB/I] ???????????????podfile?????????????????? path:#{cache_file_path}"
      end
    end
    # ??????????????????????????????target,???????????????????????????
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

  # ????????????????????????
  # Xcode??????clang???swift??????????????????????????????.d?????????????????????????????????????????????????????????????????????????????????????????????????????????
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

  #??????????????????????????????????????????????????????
  def self.lpb_get_target_source_files(target)
    files = []

    # ???????????????????????????
    #/Users/styf/Downloads/ruby_app/ZabelTest/ZabelAPP/Pods/Target Support Files/MJRefresh/MJRefresh-dummy.m
    # /Users/styf/Downloads/ruby_app/ZabelTest/ZabelAPP/Pods/MJRefresh/MJRefresh/Base/MJRefreshAutoFooter.m
    target.source_build_phase.files.each do | file |
      file_path = file.file_ref.real_path.to_s
      files.push file_path

    end

    # ???????????????
    # /Users/styf/Downloads/ruby_app/ZabelTest/ZabelAPP/Pods/MJRefresh/MJRefresh/MJRefresh.h
    # /Users/styf/Downloads/ruby_app/ZabelTest/ZabelAPP/Pods/MJRefresh/MJRefresh/Base/MJRefreshAutoFooter.h
    target.headers_build_phase.files.each do | file |
      file_path = file.file_ref.real_path.to_s
      files.push file_path

    end

    # ??????????????????  bundle?????????target????????????????????????
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
        # ???????????????????????????????????????
        Find.find(file).each do | file_in_dir |
          if File.file? file_in_dir
            expand_files.push file_in_dir
          end
        end
      end
    end
    return expand_files.uniq
  end

  #?????????????????? ?????? /Users/styf/Downloads/ruby_app/ZabelTest/ZabelAPP/
  def self.lpb_get_content_without_pwd(content)
    content = content.gsub("#{Dir.pwd}/", "").gsub(/#{Dir.pwd}(\W|$)/, '\1')
    return content
  end

  $lpb_file_md5_hash = {}
  #???????????????md5???
  def self.lpb_get_file_md5(file)
    if $lpb_file_md5_hash.has_key? file
      return $lpb_file_md5_hash[file]
    end
    md5 = Digest::MD5.hexdigest(File.read(file))
    $lpb_file_md5_hash[file] = md5
    return md5
  end

  # ??????????????????????????????
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

  # ??????????????????
  def self.lpb_clean_backup_project(project)
    command = "rm -rf \"#{project.path}/project.localpodbinary_backup_pbxproj\""
    raise unless system command
  end

  # ????????????
  def self.lpb_backup_project(project)
    command = "cp \"#{project.path}/project.pbxproj\" \"#{project.path}/project.localpodbinary_backup_pbxproj\""
    raise unless system command
  end
  # ?????????????????????
  def self.lpb_restore_project(project)
    if File.exist? "#{project.path}/project.localpodbinary_backup_pbxproj"
      command = "mv \"#{project.path}/project.localpodbinary_backup_pbxproj\" \"#{project.path}/project.pbxproj\""
      puts command
      raise unless system command
    end
  end
  # ???????????????????????????
  def self.lpb_delete_target_context_file(project,target)
    if File.exist? "#{project.path}/#{target.name}.#{FILE_NAME_TARGET_CONTEXT}"
      command = "rm -rf \"#{project.path}/#{target.name}.#{FILE_NAME_TARGET_CONTEXT}\""
      raise unless system command
    end
  end

  $lpb_podfile_spec_checksums = nil
  # ?????????????????? ??????
  # Localpodbinary version
  # ARGV ???????????????????????????????????????????????????
  # pod.lockfile?????????????????????SPEC CHECKSUMS
  # project???build_configuration?????? (??????configuration_name????????????)
  # project???xcconfig (??????SEARCH_PATHS)
  # target???build_configuration?????? (??????configuration_name????????????)
  # target???xcconfig (??????SEARCH_PATHS)
  # ?????????????????? Files settings
  #
  def self.lpb_get_target_md5_content(project, target, configuration_name, argv, source_files)

    #?????? Podfile.lock??? SPEC CHECKSUMS??????
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
    # project???build setting
    project_configuration = project.build_configurations.detect { | config | config.name == configuration_name}
    project_configuration_content = project_configuration.pretty_print.to_yaml
    # puts project_configuration_content

    #??????project???xcconfig??????
    project_xcconfig = ""
    if project_configuration.base_configuration_reference  #an optional file reference to a configuration file (`.xcconfig`)
      config_file_path = project_configuration.base_configuration_reference.real_path
      if File.exist? config_file_path
        # ??????xcconfig??????SEARCH_PATHS
        project_xcconfig = File.read(config_file_path).lines.reject{|line|line.include? "_SEARCH_PATHS"}.sort.join("")
      end
    end

    # target???build setting
    target_configuration = target.build_configurations.detect { | config | config.name == configuration_name}
    target_configuration_content = target_configuration.pretty_print.to_yaml

    #??????target???xcconfig??????
    target_xcconfig = ""
    if target_configuration.base_configuration_reference
      #Users/styf/Downloads/ruby_app/ZabelTest/ZabelAPP/Pods/Target Support Files/AFNetworking/AFNetworking.debug.xcconfig
      config_file_path = target_configuration.base_configuration_reference.real_path
      if File.exist? config_file_path
        # ??????xcconfig??????SEARCH_PATHS
        target_xcconfig = File.read(config_file_path).lines.reject{|line|line.include? "_SEARCH_PATHS"}.sort.join("")
      end
    end
    #???????????????????????????
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
      #????????????????????????
      target.source_build_phase.files_references.each do | files_reference |
        files_reference.build_files.each do |build_file|
          if build_file.settings and build_file.settings.class == Hash
            first_configuration.push File.basename(build_file.file_ref.real_path.to_s) + "\n" + build_file.settings.to_yaml
          end
        end
      end
    end
    first_configuration_content = first_configuration.sort.uniq.join("\n")
    #???????????????????????????????????????????????????
    key_argv = []
    # bundle exec zabel xcodebuild -workspace ZabelAPP.xcworkspace -configuration Debug -scheme ZabelAPP -sdk iphoneos -arch arm64
    #
    # TODO: to add more and test more
    # However, you can control your cache keys manually by using pre and post.
    # ?????????xcode??????????????????????????????????????????xcode??????????????????????????????????????????md5??????
    #
    # temp_path_list = ["-derivedDataPath", "-archivePath", "--derived_data_path", "--archive_path", "--build_path"] #??????????????????
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


    # 1.0.4------------start ???????????????spec???????????????
    # TODO: to get a explicit spec name from a target.
    target_possible_spec_names = []
    target_possible_spec_names.push target_configuration.build_settings["PRODUCT_NAME"] if target_configuration.build_settings["PRODUCT_NAME"]
    target_possible_spec_names.push target_configuration.build_settings["IBSC_MODULE"] if target_configuration.build_settings["IBSC_MODULE"]
    target_possible_spec_names.push File.basename(target_configuration.build_settings["CONFIGURATION_BUILD_DIR"]) if target_configuration.build_settings["CONFIGURATION_BUILD_DIR"]
    # ???xcconfig??????CONFIGURATION_BUILD_DIR???PODS_TARGET_SRCROOT???????????????spec??????
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

  # ??????????????????
  # ??????????????????????????????????????????????????????
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
    #?????????????????????
    unless full_product_name and full_product_name.size > 0 and File.exist? "#{product_dir}/#{full_product_name}"
      puts "[LPB/E] #{target.name} #{product_dir}/#{full_product_name} should exist"
      return false
    end

    zip_start_time = Time.now

    #??????????????????---------
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
    puts "[LPB/I] ???????????????????????????????????? #{command}"
    unless system command
      puts command
      puts "[LPB/E] #{command} should succeed"
      return false
    end
    unless File.exist? cache_product_path
      puts "[LPB/E] #{cache_product_path} should exist after mv"
      return false
    end

    #bundle???framework?????????????????????????????????md5??????????????????????????????????????????md5??????   com.apple.product-type.bundle
    if target.product_type == "com.apple.product-type.bundle" or target.product_type == "com.apple.product-type.framework"
      command = "cd \"#{target_cache_dir}\" && tar -L -c -f #{FILE_NAME_PRODUCT} #{full_product_name}"
      puts "[LPB/I] bundle?????????????????? #{command}"
      unless system command
        puts "[LPB/E] #{command} should succeed"
        return false
      end
      cache_product_path = target_cache_dir + "/#{FILE_NAME_PRODUCT}"
    end
    #??????????????????---------

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
    #????????????????????????
    File.write(target_cache_dir + "/" + FILE_NAME_CONTEXT, target_context.to_yaml)
    File.write(target_cache_dir + "/" + FILE_NAME_MESSAGE, message)

    return true
  end

  #????????????????????????????????????????????????????????????
  # ??????????????????????????????????????????target_md5???product_md5
  # 1.0.4?????? miss_dependency_list
  def self.lpb_get_potential_hit_target_cache_dirs(target, target_md5,miss_dependency_list)
    dependency_start_time = Time.now
    target_cache_dirs = Dir.glob(lpb_get_cache_root + "/" + target.name + "-" + target_md5 + "-*")
    # ???????????????["/Users/styf/zabel/AFNetworking-76658271cc8f3a683609e0b97fdb46ba-1628834493476"]
    # puts "???????????????#{target_cache_dirs}"
    file_time_hash = {}
    target_cache_dirs.each do | file |
      file_time_hash[file] = File.mtime(file) #????????????????????????
    end
    target_cache_dirs = target_cache_dirs.sort_by {|file| - file_time_hash[file].to_f}
    potential_hit_target_cache_dirs = []
    target_cache_dirs.each do | target_cache_dir |
      next unless File.exist? target_cache_dir + "/" + FILE_NAME_CONTEXT
      target_context = YAML.load(File.read(target_cache_dir + "/" + FILE_NAME_CONTEXT))
      full_product_name = target_context[BUILD_KEY_FULL_PRODUCT_NAME]
      next unless File.exist? target_cache_dir + "/" + full_product_name

      dependency_miss = false
      #??????????????????????????????md5????????????
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
          #1.0.4??????
          miss_dependency_list.push "[LPB/W] #{target.name} #{dependency_file} file should exist to be hit"
          dependency_miss = true
          break
        end
        unless lpb_get_file_md5(dependency_file) == dependency_md5
          puts "[LPB/W] #{target.name} #{dependency_file} md5 should match to be hit"
          #1.0.4??????
          miss_dependency_list.push "[LPB/W] #{target.name} #{dependency_file} md5 #{lpb_get_file_md5(dependency_file)} should match #{dependency_md5} to be hit"
          dependency_miss = true
          break
        end
      end

      #????????????????????????md5?????????
      if not dependency_miss
        #??????target_md5
        if not target_context[:target_md5] == target_md5
          command = "rm -rf \"#{target_cache_dir}\""
          raise unless system command
          puts "[LPB/E] #{target.name} #{target_cache_dir} target md5 should match to be verified"
          dependency_miss = false
          next
        end
        #??????product_md5     product.tar???md5
        product_md5_path = target_cache_dir + "/" + target_context[BUILD_KEY_FULL_PRODUCT_NAME]
        if target.product_type == "com.apple.product-type.bundle" or target.product_type == "com.apple.product-type.framework" #bundle???framework???md5??????????????????????????????
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
    puts "#{target_name}????????????????????????"
  end

  #???????????????????????????????????????  localBinary_pod_printenv
  def self.lpb_inject_localBinary_pod_printenv(target)
    execshell = "\"${SRCROOT}/../cocoapods-localpodbinary/shell/LocalPodBinary_PrintENV.sh\""
    inject_phase = target.new_shell_script_build_phase("localpodbinary_printenv_#{target.name}")
    inject_phase.shell_script = "#{execshell}"
    inject_phase.show_env_vars_in_log = '1'
  end

  #????????????????????????????????????  localBinary_produce
  def self.lpb_inject_localBinary_main_produce(main_target)
    execshell = "cd \"${SRCROOT}\" && \"cocoapods-localpodbinary/shell/LocalPodBinary_Produce.sh\""
    #?????????????????????????????????????????????xcodeproj???????????????????????????xcodeproj?????????????????????????????????????????????
    main_xcodeproj_path_array = Dir.glob("*.xcodeproj")#???????????????????????????????????????
    if main_xcodeproj_path_array.size == 0
      execshell = "cd \"${SRCROOT}/..\" && \"cocoapods-localpodbinary/shell/LocalPodBinary_Produce.sh\""
    end

    inject_phase = main_target.new_shell_script_build_phase(PRODUCE_SHELL_NAME)
    inject_phase.shell_script = "#{execshell}"
    inject_phase.show_env_vars_in_log = '1'
    puts "[LPB/I] ???????????????????????????"
  end

  # ????????????
  def self.consume

    # ??????debug???????????????
    configuration_name = "Debug"

    start_time = Time.now

    #?????????????????????
    main_project = lpb_get_main_project
    main_project_name = File.basename(main_project.path).split(".")[0]
    unless main_project
      puts "[LPB/E] ??????????????????"
      return
    end

    #???????????????????????????target
    main_target = lpb_get_main_target(main_project,main_project_name)
    unless main_target
      puts "[LPB/E] ???target?????????"
      return
    end

    #?????????target???xcconfig
    main_target_configuration = main_target.build_configurations.detect { | config | config.name == configuration_name}
    main_target_xcconfig = "" #?????????xcconfig?????????
    main_target_xcconfig_path = "" #?????????xcconfig?????????
    if main_target_configuration.base_configuration_reference
      main_target_xcconfig_path = main_target_configuration.base_configuration_reference.real_path
      if File.exist? main_target_xcconfig_path
        main_target_xcconfig = File.read(main_target_xcconfig_path)
      else
        puts "[LPB/E] ????????????????????????xcconfig?????????#{config_file_path}"
        return
      end
    end

    #??????????????????pod??????????????????
    pod_resources_shell_path = "Pods/Target Support Files/Pods-#{main_project_name}/Pods-#{main_project_name}-resources.sh"
    pod_resources_shell = "" #pod??????????????????
    if File.exist? pod_resources_shell_path
      pod_resources_shell = File.read(pod_resources_shell_path)
    else
      puts "[LPB/E] pod????????????????????????#{pod_resources_shell_path}"
      return
    end
    puts "[LBP/I] ?????????????????????xccofig???pod????????????"

    #?????????target???????????????
    lpb_delete_main_target_produce_shell(main_project,main_target)

    #????????????????????????
    lpb_clean_temp_files
    puts "[LPB/I] ????????????Pod?????????????????????????????????????????????"

    #????????????xcodeproj????????????
    projects = lpb_get_projects

    pre_targets_context = {}

    hit_count = 0
    miss_count = 0
    hit_target_md5_cache_set = Set.new
    iteration_count = 0
    # Pods-XXXX
    pod_target = nil

    projects.each do | project |
      #1.0.4??????
      project_configuration = project.build_configurations.detect { | config | config.name == configuration_name}
      unless project_configuration
        puts "[LPB/E] #{project.path} should have config #{configuration_name}"
        next
      end

      project.native_targets.each do | target |
        if target.name.start_with? "Pods-"
          pod_target = target
        end
        #target????????????
        if lpb_can_cache_target(target)  #?????????Pods-XXX ??????????????????????????????????????????
          #??????????????????????????????????????????????????????
          source_files = lpb_get_target_source_files(target)
          next unless source_files.size >= lpb_get_min_source_file_count
          argv = {}
          target_md5_content = lpb_get_target_md5_content(project, target, configuration_name, argv, source_files)
          #?????????target????????????????????????md5??????md5???
          target_md5 = Digest::MD5.hexdigest(target_md5_content)
          #?????????????????????????????????????????????
          miss_dependency_list = []
          potential_hit_target_cache_dirs = lpb_get_potential_hit_target_cache_dirs(target, target_md5,miss_dependency_list)

          target_context = {}
          target_context[:target_md5] = target_md5
          target_context[:potential_hit_target_cache_dirs] = potential_hit_target_cache_dirs
          target_context[:miss_dependency_list] = miss_dependency_list
          target_context[:target_md5_content] = target_md5_content
          target_context[:source_files] = source_files
          if potential_hit_target_cache_dirs.size == 0
            # 1.0.4?????????????????????
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
      #??????????????????
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
            #??????????????????????????????????????????
            hit_target_context = YAML.load(File.read(target_cache_dir + "/" + FILE_NAME_CONTEXT))
            hit_target_cache_dir = target_cache_dir
            # ?????????????????????targets
            hit_target_context[:dependency_targets_md5].each do | item |
              dependency_target = item[0]
              dependency_target_md5 = item[1]

              # cycle dependency targets will be miss every time.
              # TODO: to detect cycle dependency so that cache will not be added,
              # or to hit cache together with some kind of algorithms.

              # ??????????????????target ??????????????????????????? ????????????????????? ??????????????????????????????????????????????????????
              # ?????????????????????????????????????????????Miss??????hit_target_md5_cache_set????????????????????????hit_target_cache_dir???????????????????????????
              # ????????????????????????????????????????????????????????????????????????????????????????????????MISS?????????????????????????????????
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
          #???????????????
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
        #?????????????????????????????????????????????????????????
        break
      end
    end

    #?????????pre_targets_context??????????????????????????????
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
            # 2 ?????? Pods-XXXX-resource.sh ??????
            #  install_resource "${PODS_CONFIGURATION_BUILD_DIR}/WPTAllSeeingEyeModule/WPTAESBundle.bundle"
            #  bundle???target?????? WPTAllSeeingEyeModule-WPTAESBundle  ????????????

            bundle_target_name = target.name.split("-")[0]
            pod_resources_shell = pod_resources_shell.gsub("${PODS_CONFIGURATION_BUILD_DIR}/#{bundle_target_name}", target_cache_dir)
            File.write(pod_resources_shell_path, pod_resources_shell)
            puts "[LPB/I] #{target.name} ??????pod????????????"
          else
            # PODS_CONFIGURATION_BUILD_DIR\=/Users/styf/Library/Developer/Xcode/DerivedData/LocalCacheAPP-ezyfamlzjecangaabdcjoovrrlot/Build/Products/Debug-iphoneos
            # PODS_CONFIGURATION_BUILD_DIR=${PODS_BUILD_DIR}/$(CONFIGURATION)$(EFFECTIVE_PLATFORM_NAME)
            # PODS_BUILD_DIR = BUILD_DIR\=/Users/styf/Library/Developer/Xcode/DerivedData/LocalCacheAPP-ezyfamlzjecangaabdcjoovrrlot/Build/Products
            #
            # 1 ??????????????????xcconfig
            # 1.1 FRAMEWORK_SEARCH_PATHS----?????????PODS_CONFIGURATION_BUILD_DIR?????????????????????framework
            # "${PODS_CONFIGURATION_BUILD_DIR}/WPTDataTracker"
            # 1.2 HEADER_SEARCH_PATHS----.a??????????????????????????????framework??????????????????????????????framework
            # "${PODS_CONFIGURATION_BUILD_DIR}/WPTDataTracker/WPTDataTracker.framework/Headers"
            # 1.3 LIBRARY_SEARCH_PATHS----???????????????PODS_CONFIGURATION_BUILD_DIR???.a
            # "${PODS_CONFIGURATION_BUILD_DIR}/AFNetworking"
            # 1.4 OTHER_CFLAGS----??????????????????PODS_CONFIGURATION_BUILD_DIR?????????????????????
            # -iframework "${PODS_CONFIGURATION_BUILD_DIR}/WPTDataTracker"
            # 1.5 OTHER_LDFLAGS----???????????????????????????,????????????PODS_CONFIGURATION_BUILD_DIR
            # -force_load ${PODS_CONFIGURATION_BUILD_DIR}/WPTDataTracker/WPTDataTracker.framework/WPTDataTracker
            #
            # ??????????????????????????????
            #
            # "/Users/styf/localPodBinary/SDWebImage-b4deaf3e64d98f94171b9054a033682f-1629968158141"
            # "/Users/styf/localPodBinary/SDWebImageWebPCoder-9dc98b8869b80589e8a18cd4b9c4ac04-1629968158231"

            main_target_xcconfig = main_target_xcconfig.gsub("\"${PODS_CONFIGURATION_BUILD_DIR}/#{target.name}\"", "\"#{target_cache_dir}\"")
            main_target_xcconfig = main_target_xcconfig.gsub("${PODS_CONFIGURATION_BUILD_DIR}/#{target.name}/", "#{target_cache_dir}/")
            File.write(main_target_xcconfig_path, main_target_xcconfig)
            puts "[LPB/I] #{target.name} ???????????????xcconfig??????"
          end

        else
          unless target_context[:target_status] == STATUS_MISS
            #??????????????????????????????Miss
            target_context[:target_status] = STATUS_MISS
            #?????????????????????
            miss_dependency_list = target_context[:miss_dependency_list]
            if miss_dependency_list.size > 0
              puts miss_dependency_list.uniq.join("\n")
            end
            puts "[LBP/I] miss #{target.name} #{target_context[:target_md5]} in iteration #{iteration_count}"
            miss_count = miss_count + 1
          end
          # ??????????????? printenv ??????????????????
          lpb_inject_localBinary_pod_printenv(target)

          # ?????????????????????????????? ??????????????????
          File.write("#{project.path}/#{target.name}.#{FILE_NAME_TARGET_CONTEXT}", target_context.to_yaml)
          #??????????????????????????????
          lpb_backup_project(project)
        end
        should_save = true
      end
      if should_save
        project.save
      end
    end

    if miss_count > 0
      # ???????????????????????????produce
      lpb_inject_localBinary_main_produce(main_target)
      main_project.save
    end

    puts "[LBP/I] total #{hit_count + miss_count} hit #{hit_count} miss #{miss_count} iteration #{iteration_count}"

    puts "[LBP/I] duration = #{(Time.now - start_time).to_i} s in stage pre"
  end

  # ???????????????Xcode?????????????????????  ????????????
  def self.produce
    #????????????????????????
    configuration_name = nil

    if ENV[BUILD_KEY_CONFIGURATION]
      configuration_name = ENV[BUILD_KEY_CONFIGURATION]
    end
    unless configuration_name and configuration_name.size > 0
      raise "[LPB/E] -configuration or --configuration should be set"
    end
    # ???debug??????????????????
    return unless configuration_name == "Debug"

    start_time = Time.now
    #???????????????LPB_CLEAR_ALL??????????????????????????????
    if ENV["LPB_CLEAR_ALL"] == "YES"
      command = "rm -rf \"#{lpb_get_cache_root}\""
      puts command
      raise unless system command
    end

    #?????????????????????
    main_project = lpb_get_main_project
    main_project_name = File.basename(main_project.path).split(".")[0]
    unless main_project
      puts "[LPB/E] ??????????????????"
      return
    end

    #???????????????????????????target
    main_target = lpb_get_main_target(main_project,main_project_name)
    unless main_target
      puts "[LPB/E] ???target?????????"
      return
    end

    add_count = 0
    #????????????xcodeproj????????????
    projects = lpb_get_projects

    pre_targets_context = {}

    hit_count = 0
    miss_count = 0
    hit_target_md5_cache_set = Set.new
    iteration_count = 0

    projects.each do | project |
      #1.0.4??????
      project_configuration = project.build_configurations.detect { | config | config.name == configuration_name}
      unless project_configuration
        puts "[LPB/E] #{project.path} should have config #{configuration_name}"
        next
      end

      project.native_targets.each do | target |
        target_context_file = "#{project.path}/#{target.name}.#{FILE_NAME_TARGET_CONTEXT}"
        unless File.exist? target_context_file #??????????????????????????????  ???????????????????????????????????????
          next
        end
        #target????????????
        if lpb_can_cache_target(target)  #?????????Pods-XXX ??? ?????????????????????????????????
          target_context = YAML.load(File.read(target_context_file))
          #puts "???????????????#{target_context[:target_status]}"
          if target_context[:target_status] == STATUS_MISS
            #??????miss???????????????target_context?????????

            # ??????????????????????????????????????????????????????
            source_files = target_context[:source_files]
            # miss????????? ?????? printenv????????????????????????
            product_dir = target_context[BUILD_KEY_CONFIGURATION_BUILD_DIR]
            intermediate_dir = target_context[BUILD_KEY_TARGET_TEMP_DIR]
            xcframeworks_build_dir = target_context[BUILD_KEY_PODS_XCFRAMEWORKS_BUILD_DIR]
            # ???????????????.d???????????????????????????????????????
            dependency_files = lpb_get_dependency_files(target, intermediate_dir, product_dir, xcframeworks_build_dir)
            if source_files.size > 0 and dependency_files.size == 0 and target.product_type != "com.apple.product-type.bundle"
              puts "[LPB/E] #{target.name} should have dependent files"
              next
            end
            # ????????????????????????????????????????????????
            target_context[:dependency_files] = dependency_files - source_files
            # ????????????????????????????????????md5

            argv = {}
            # ????????????md5??????????????????
            target_md5_content = lpb_get_target_md5_content(project, target, configuration_name, argv, source_files)
            target_context[:target_md5_content] = target_md5_content
            target_md5 = Digest::MD5.hexdigest(target_md5_content)
            unless target_context[:target_md5] == target_md5
              puts "[LPB/E] #{target.name} md5 should not be changed after build"
              next
            end
            # ??????modulemap
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
            # ???????????????????????????????????????????????????????????????????????????
            # ??????modulemap
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

    #??????miss??????
    projects.each do | project |
      need_restore = false
      project.native_targets.each do | target |
        if pre_targets_context.has_key? target
          target_context = pre_targets_context[target]
          next unless target_context[:target_status] == STATUS_MISS
          #??????miss??????
          dependency_targets_set = Set.new
          implicit_dependencies = []
          need_restore = true

          pre_targets_context.each do | other_target, other_target_context |
            next if other_target == target

            next if target.product_type == "com.apple.product-type.bundle"
            next if other_target.product_type == "com.apple.product-type.bundle"
            # ????????????????????????????????????
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
          # 1.0.4??????
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

          # ????????????????????? 1.0.4??????
          target_context[:dependency_files_md5] = dependency_files_md5.sort.uniq
          # ???????????????????????????
          dependency_targets_md5 = dependency_targets_set.to_a.map { | target |  [target.name, pre_targets_context[target][:target_md5]]}
          target_context[:dependency_targets_md5] = dependency_targets_md5

          message = target_context[:target_md5_content]
          # ??????????????????
          if lpb_add_cache(target, target_context, message)
            add_count = add_count + 1
            #???????????????????????????
            lpb_delete_target_context_file(project,target)
          end
        end
      end
      if need_restore
        #??????pod??????????????????????????????
        puts "[LPB/I] ????????????"
        lpb_restore_project(project)
      end
    end

    lpb_keep

    #?????????target???????????????
    lpb_delete_main_target_produce_shell(main_project,main_target)

    puts "[LPB/I] total add #{add_count}"

    puts "[LPB/I] duration = #{(Time.now - start_time).to_i} s in stage post"

  end

  def self.clean
    lpb_clean_temp_files
  end

end
