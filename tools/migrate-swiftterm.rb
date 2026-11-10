# One-off project migration: hterm/WKWebView -> SwiftTerm. Kept for reference.
require 'xcodeproj'
root = File.expand_path('..', __dir__)
project = Xcodeproj::Project.open(File.join(root, 'iSH.xcodeproj'))
t = ->(name) { project.targets.find { |x| x.name == name } or raise "no target #{name}" }

libs = [t.('libiSHApp'), t.('libiSHLinux')]
apps = [t.('iSH'), t.('iSH+Linux')]

# Local Swift package
pkg = project.root_object.package_references.find { |r| r.respond_to?(:relative_path) && r.relative_path == 'deps/SwiftTerm' }
unless pkg
  pkg = project.new(Xcodeproj::Project::Object::XCLocalSwiftPackageReference)
  pkg.relative_path = 'deps/SwiftTerm'
  project.root_object.package_references << pkg
end

(libs + apps).each do |target|
  next if target.package_product_dependencies.any? { |d| d.product_name == 'SwiftTerm' }
  dep = project.new(Xcodeproj::Project::Object::XCSwiftPackageProductDependency)
  dep.package = pkg
  dep.product_name = 'SwiftTerm'
  target.package_product_dependencies << dep
  if apps.include?(target)
    bf = project.new(Xcodeproj::Project::Object::PBXBuildFile)
    bf.product_ref = dep
    target.frameworks_build_phase.files << bf
  end
end

# Swift source
group = project.main_group.recursive_children.find { |g| g.isa == 'PBXGroup' && g.children.any? { |c| c.respond_to?(:path) && c.path == 'TerminalView.m' } }
ref = group.files.find { |f| f.path == 'TerminalSurface.swift' } || group.new_file('TerminalSurface.swift')
libs.each do |target|
  target.add_file_references([ref]) unless target.source_build_phase.files_references.include?(ref)
  target.build_configurations.each do |c|
    c.build_settings['SWIFT_OBJC_INTERFACE_HEADER_NAME'] = 'iSHSwift.h'
    c.build_settings['SWIFT_VERSION'] = '5.0'
    c.build_settings['CLANG_ENABLE_MODULES'] = 'YES'
  end
end

# Drop the web terminal
web = %w[hterm_all.js term.js term.css term.html]
project.targets.each do |target|
  target.build_phases.grep(Xcodeproj::Project::Object::PBXShellScriptBuildPhase).each do |phase|
    phase.remove_from_project if phase.name == 'Compile JavaScript'
  end
  target.resources_build_phase.files.dup.each do |bf|
    bf.remove_from_project if bf.file_ref && web.include?(bf.file_ref.display_name)
  end if target.respond_to?(:resources_build_phase)
  target.source_build_phase.files.dup.each do |bf|
    bf.remove_from_project if bf.file_ref && bf.file_ref.display_name == 'ScrollbarView.m'
  end if target.respond_to?(:source_build_phase)
end
project.files.dup.each do |f|
  f.remove_from_project if (web + %w[ScrollbarView.m ScrollbarView.h]).include?(f.display_name)
end

project.save
puts 'ok'

# Second pass: static libraries only get a build-order dependency on a package
# product when it is listed in their Link Binary phase.
project = Xcodeproj::Project.open(File.join(root, 'iSH.xcodeproj'))
%w[libiSHApp libiSHLinux].each do |name|
  target = project.targets.find { |x| x.name == name }
  dep = target.package_product_dependencies.find { |d| d.product_name == 'SwiftTerm' }
  next if target.frameworks_build_phase.files.any? { |f| f.product_ref == dep }
  bf = project.new(Xcodeproj::Project::Object::PBXBuildFile)
  bf.product_ref = dep
  target.frameworks_build_phase.files << bf
end
project.save
puts 'ok2'

# Third pass: a static library's Link Binary phase merges the package product into
# the .a, so the apps must not link SwiftTerm again (duplicate symbols).
project = Xcodeproj::Project.open(File.join(root, 'iSH.xcodeproj'))
%w[iSH iSH+Linux].each do |name|
  target = project.targets.find { |x| x.name == name }
  target.package_product_dependencies.select { |d| d.product_name == 'SwiftTerm' }.each do |dep|
    target.frameworks_build_phase.files.select { |f| f.product_ref == dep }.each(&:remove_from_project)
    target.package_product_dependencies.delete(dep)
    dep.remove_from_project
  end
end
project.save
puts 'ok3'

# Fourth pass: give the app targets a Swift source so they link with the Swift driver.
project = Xcodeproj::Project.open(File.join(root, 'iSH.xcodeproj'))
group = project.main_group.recursive_children.find { |g| g.isa == 'PBXGroup' && g.children.any? { |c| c.respond_to?(:path) && c.path == 'TerminalView.m' } }
ref = group.files.find { |f| f.path == 'SwiftLinkage.swift' } || group.new_file('SwiftLinkage.swift')
%w[iSH iSH+Linux].each do |name|
  target = project.targets.find { |x| x.name == name }
  target.add_file_references([ref]) unless target.source_build_phase.files_references.include?(ref)
  target.build_configurations.each { |c| c.build_settings['SWIFT_VERSION'] = '5.0' }
end
project.save
puts 'ok4'
