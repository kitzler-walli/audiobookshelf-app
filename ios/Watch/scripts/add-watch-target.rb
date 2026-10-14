#!/usr/bin/env ruby
# Adds the standalone watchOS app target to ios/App/App.xcodeproj and embeds it in the iOS app.
# Run from anywhere: `ruby ios/Watch/scripts/add-watch-target.rb`. When the target already exists, it only syncs the
# watch app's Swift files with the folder (adds new files, drops deleted ones).
#
# Kept as a script (instead of clicking through Xcode) so the target can be recreated after an upstream merge
# overwrites project.pbxproj.
require 'xcodeproj'

PROJECT_PATH = File.expand_path('../../App/App.xcodeproj', __dir__)
WATCH_NAME = 'AudiobookshelfWatch'
IOS_TARGET = 'Audiobookshelf'
TEAM = 'XM4N953GC3'

SOURCE_DIR = File.expand_path("../#{WATCH_NAME}", __dir__)

def swift_files
  Dir.glob(File.join(SOURCE_DIR, '*.swift')).map { |path| File.basename(path) }.sort
end

project = Xcodeproj::Project.open(PROJECT_PATH)
if (existing = project.targets.find { |t| t.name == WATCH_NAME })
  group = project.main_group.children.find { |g| g.display_name == WATCH_NAME } or abort "#{WATCH_NAME} group not found"
  on_disk = swift_files
  group.files.select { |f| f.path.end_with?('.swift') && !on_disk.include?(f.path) }.each do |ref|
    existing.source_build_phase.remove_file_reference(ref)
    ref.remove_from_project
    puts "removed #{ref.path}"
  end
  known = group.files.map(&:path)
  (on_disk - known).each do |name|
    existing.add_file_references([group.new_file(name)])
    puts "added #{name}"
  end
  project.save
  puts "#{WATCH_NAME} sources in sync"
  exit 0
end
ios = project.targets.find { |t| t.name == IOS_TARGET } or abort "iOS target #{IOS_TARGET} not found"
ios_release = ios.build_configurations.find { |c| c.name == 'Release' }.build_settings

# Local Swift package references need the Xcode 15 project format
project.root_object.instance_variable_set(:@object_version, nil)
project.instance_variable_set(:@object_version, '60')

watch = project.new_target(:application, WATCH_NAME, :watchos, '27.0', nil, :swift)

# Sources and resources, paths relative to ios/App
group = project.main_group.new_group(WATCH_NAME, "../Watch/#{WATCH_NAME}")
swift_files.each { |name| watch.add_file_references([group.new_file(name)]) }
watch.add_resources([group.new_file('Assets.xcassets')])
group.new_file('Info.plist')

# AbsWatchCore local package
package = project.new(Xcodeproj::Project::Object::XCLocalSwiftPackageReference)
package.relative_path = '../Watch/AbsWatchCore'
project.root_object.package_references << package
product = project.new(Xcodeproj::Project::Object::XCSwiftPackageProductDependency)
product.product_name = 'AbsWatchCore'
product.package = package
watch.package_product_dependencies << product
build_file = project.new(Xcodeproj::Project::Object::PBXBuildFile)
build_file.product_ref = product
watch.frameworks_build_phase.files << build_file

watch.build_configurations.each do |config|
  dev = config.name == 'Debug'
  companion = dev ? 'kw.audiobookshelf.app.dev' : 'kw.audiobookshelf.app'
  config.build_settings.merge!(
    'PRODUCT_NAME' => WATCH_NAME,
    'PRODUCT_BUNDLE_IDENTIFIER' => "#{companion}.watchkitapp",
    'ABS_COMPANION_BUNDLE_ID' => companion,
    'INFOPLIST_FILE' => "../Watch/#{WATCH_NAME}/Info.plist",
    'GENERATE_INFOPLIST_FILE' => 'NO',
    'ASSETCATALOG_COMPILER_APPICON_NAME' => 'AppIcon',
    'DEVELOPMENT_TEAM' => TEAM,
    'CODE_SIGN_STYLE' => 'Automatic',
    'SWIFT_VERSION' => '5.0',
    'WATCHOS_DEPLOYMENT_TARGET' => '27.0',
    'TARGETED_DEVICE_FAMILY' => '4',
    'SKIP_INSTALL' => 'YES',
    'LD_RUNPATH_SEARCH_PATHS' => '$(inherited) @executable_path/Frameworks',
    # An embedded watch app must carry the same versions as the iOS app
    'MARKETING_VERSION' => ios_release['MARKETING_VERSION'],
    'CURRENT_PROJECT_VERSION' => ios_release['CURRENT_PROJECT_VERSION']
  )
end

# iOS side of the pairing (WatchConnectivity + device-code authorization)
app_group = project.main_group.children.find { |g| g.display_name == 'App' } or abort 'App group not found'
watch_group = app_group.children.find { |g| g.display_name == 'Watch' } || app_group.new_group('Watch', 'Watch')
ios.add_file_references([watch_group.new_file('WatchPairingService.swift')])

# Embed in the iOS app: Audiobookshelf.app/Watch/AudiobookshelfWatch.app
embed = ios.new_copy_files_build_phase('Embed Watch Content')
embed.dst_subfolder_spec = '16'
embed.dst_path = '$(CONTENTS_FOLDER_PATH)/Watch'
embed.add_file_reference(watch.product_reference, true).settings = { 'ATTRIBUTES' => ['RemoveHeadersOnCopy'] }
ios.add_dependency(watch)

project.save

scheme = Xcodeproj::XCScheme.new
scheme.configure_with_targets(watch, nil, launch_target: true)
scheme.save_as(PROJECT_PATH, WATCH_NAME, true)

puts "Added #{WATCH_NAME} (watchOS 27, #{ios_release['MARKETING_VERSION']} build #{ios_release['CURRENT_PROJECT_VERSION']}) embedded in #{IOS_TARGET}"
