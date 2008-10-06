#!/usr/bin/env ruby
require 'rubygems'
require 'thor'
require 'fileutils'
require 'yaml'

##############################################################################

module ColorfulMessages
  
  # red
  def error(*messages)
    puts messages.map { |msg| "\033[1;31m#{msg}\033[0m" }
  end
  
  # yellow
  def warning(*messages)
    puts messages.map { |msg| "\033[1;33m#{msg}\033[0m" }
  end
  
  # green
  def success(*messages)
    puts messages.map { |msg| "\033[1;32m#{msg}\033[0m" }
  end
  
  alias_method :message, :success
  
  def note(*messages)
    puts messages.map { |msg| "\033[1;35m#{msg}\033[0m" }
  end
  
end

##############################################################################

require 'rubygems/dependency_installer'
require 'rubygems/uninstaller'
require 'rubygems/dependency'

module GemManagement
  
  include ColorfulMessages
  
  # Install a gem - looks remotely and local gem cache;
  # won't process rdoc or ri options.
  def install_gem(gem, options = {})
    refresh = options.delete(:refresh) || []
    from_cache = (options.key?(:cache) && options.delete(:cache))
    if from_cache
      install_gem_from_cache(gem, options)
    else
      version = options.delete(:version)
      Gem.configuration.update_sources = false

      update_source_index(options[:install_dir]) if options[:install_dir]

      installer = Gem::DependencyInstaller.new(options.merge(:user_install => false))
      
      # Exclude gems to refresh from index - force (re)install of new version
      # def installer.source_index; @source_index; end
      unless refresh.empty?
        source_index = installer.instance_variable_get(:@source_index)
        source_index.gems.each do |name, spec| 
          source_index.gems.delete(name) if refresh.include?(spec.name)
        end
      end
      
      exception = nil
      begin
        installer.install gem, version
      rescue Gem::InstallError => e
        exception = e
      rescue Gem::GemNotFoundException => e
        if from_cache && gem_file = find_gem_in_cache(gem, version)
          puts "Located #{gem} in gem cache..."
          installer.install gem_file
        else
          exception = e
        end
      rescue => e
        exception = e
      end
      if installer.installed_gems.empty? && exception
        error "Failed to install gem '#{gem} (#{version})' (#{exception.message})"
      end
      installer.installed_gems.each do |spec|
        success "Successfully installed #{spec.full_name}"
      end
      return !installer.installed_gems.empty?
    end
  end

  # Install a gem - looks in the system's gem cache instead of remotely;
  # won't process rdoc or ri options.
  def install_gem_from_cache(gem, options = {})
    version = options.delete(:version)
    Gem.configuration.update_sources = false
    installer = Gem::DependencyInstaller.new(options.merge(:user_install => false))
    exception = nil
    begin
      if gem_file = find_gem_in_cache(gem, version)
        puts "Located #{gem} in gem cache..."
        installer.install gem_file
      else
        raise Gem::InstallError, "Unknown gem #{gem}"
      end
    rescue Gem::InstallError => e
      exception = e
    end
    if installer.installed_gems.empty? && exception
      error "Failed to install gem '#{gem}' (#{e.message})"
    end
    installer.installed_gems.each do |spec|
      success "Successfully installed #{spec.full_name}"
    end
  end

  # Install a gem from source - builds and packages it first then installs.
  def install_gem_from_src(gem_src_dir, options = {})
    if !File.directory?(gem_src_dir)
      raise "Missing rubygem source path: #{gem_src_dir}"
    end
    if options[:install_dir] && !File.directory?(options[:install_dir])
      raise "Missing rubygems path: #{options[:install_dir]}"
    end

    gem_name = File.basename(gem_src_dir)
    gem_pkg_dir = File.expand_path(File.join(gem_src_dir, 'pkg'))

    # We need to use local bin executables if available.
    thor = "#{Gem.ruby} -S #{which('thor')}"
    rake = "#{Gem.ruby} -S #{which('rake')}"

    # Handle pure Thor installation instead of Rake
    if File.exists?(File.join(gem_src_dir, 'Thorfile'))
      # Remove any existing packages.
      FileUtils.rm_rf(gem_pkg_dir) if File.directory?(gem_pkg_dir)
      # Create the package.
      FileUtils.cd(gem_src_dir) { system("#{thor} :package") }
      # Install the package using rubygems.
      if package = Dir[File.join(gem_pkg_dir, "#{gem_name}-*.gem")].last
        FileUtils.cd(File.dirname(package)) do
          install_gem(File.basename(package), options.dup)
          return true
        end
      else
        raise Gem::InstallError, "No package found for #{gem_name}"
      end
    # Handle elaborate installation through Rake
    else
      # Clean and regenerate any subgems for meta gems.
      Dir[File.join(gem_src_dir, '*', 'Rakefile')].each do |rakefile|
        FileUtils.cd(File.dirname(rakefile)) do 
          system("#{rake} clobber_package; #{rake} package")
        end
      end

      # Handle the main gem install.
      if File.exists?(File.join(gem_src_dir, 'Rakefile'))
        subgems = []
        # Remove any existing packages.
        FileUtils.cd(gem_src_dir) { system("#{rake} clobber_package") }
        # Create the main gem pkg dir if it doesn't exist.
        FileUtils.mkdir_p(gem_pkg_dir) unless File.directory?(gem_pkg_dir)
        # Copy any subgems to the main gem pkg dir.
        Dir[File.join(gem_src_dir, '*', 'pkg', '*.gem')].each do |subgem_pkg|
          if name = File.basename(subgem_pkg, '.gem')[/^(.*?)-([\d\.]+)$/, 1]
            subgems << name
          end
          dest = File.join(gem_pkg_dir, File.basename(subgem_pkg))
          FileUtils.copy_entry(subgem_pkg, dest, true, false, true)          
        end

        # Finally generate the main package and install it; subgems
        # (dependencies) are local to the main package.
        FileUtils.cd(gem_src_dir) do         
          system("#{rake} package")
          FileUtils.cd(gem_pkg_dir) do
            if package = Dir[File.join(gem_pkg_dir, "#{gem_name}-*.gem")].last
              # If the (meta) gem has it's own package, install it.
              install_gem(File.basename(package), options.merge(:refresh => subgems))
            else
              # Otherwise install each package seperately.
              Dir["*.gem"].each { |gem| install_gem(gem, options.dup) }
            end
          end
          return true
        end
      end
    end
    raise Gem::InstallError, "No Rakefile found for #{gem_name}"
  end

  # Uninstall a gem.
  def uninstall_gem(gem, options = {})
    if options[:version] && !options[:version].is_a?(Gem::Requirement)
      options[:version] = Gem::Requirement.new ["= #{options[:version]}"]
    end
    update_source_index(options[:install_dir]) if options[:install_dir]
    Gem::Uninstaller.new(gem, options).uninstall
  end

  # Use the local bin/* executables if available.
  def which(executable)
    if File.executable?(exec = File.join(Dir.pwd, 'bin', executable))
      exec
    else
      executable
    end
  end
  
  # Create a modified executable wrapper in the specified bin directory.
  def ensure_bin_wrapper_for(gem_dir, bin_dir, *gems)
    if bin_dir && File.directory?(bin_dir)
      gems.each do |gem|
        if gemspec_path = Dir[File.join(gem_dir, 'specifications', "#{gem}-*.gemspec")].last
          spec = Gem::Specification.load(gemspec_path)
          spec.executables.each do |exec|
            executable = File.join(bin_dir, exec)
            message "Writing executable wrapper #{executable}"
            File.open(executable, 'w', 0755) do |f|
              f.write(executable_wrapper(spec, exec))
            end
          end
        end
      end
    end
  end

  private

  def executable_wrapper(spec, bin_file_name)
    <<-TEXT
#!/usr/bin/env ruby
#
# This file was generated by Merb's GemManagement
#
# The application '#{spec.name}' is installed as part of a gem, and
# this file is here to facilitate running it.

begin 
  require 'minigems'
rescue LoadError 
  require 'rubygems'
end

if File.directory?(gems_dir = File.join(Dir.pwd, 'gems')) ||
   File.directory?(gems_dir = File.join(File.dirname(__FILE__), '..', 'gems'))
  $BUNDLE = true; Gem.clear_paths; Gem.path.unshift(gems_dir)
end

version = "#{Gem::Requirement.default}"

if ARGV.first =~ /^_(.*)_$/ and Gem::Version.correct? $1 then
  version = $1
  ARGV.shift
end

gem '#{spec.name}', version
load '#{bin_file_name}'
TEXT
  end

  def find_gem_in_cache(gem, version)
    spec = if version
      version = Gem::Requirement.new ["= #{version}"] unless version.is_a?(Gem::Requirement)
      Gem.source_index.find_name(gem, version).first
    else
      Gem.source_index.find_name(gem).sort_by { |g| g.version }.last
    end
    if spec && File.exists?(gem_file = "#{spec.installation_path}/cache/#{spec.full_name}.gem")
      gem_file
    end
  end

  def update_source_index(dir)
    Gem.source_index.load_gems_in(File.join(dir, 'specifications'))
  end
  
end

##############################################################################

module MerbThorHelper
  
  def self.included(base)
    base.send(:include, ColorfulMessages)
    base.extend ColorfulMessages
  end
  
  # The current working directory, or Merb app root (--merb-root option).
  def working_dir
    @_working_dir ||= File.expand_path(options['merb-root'] || Dir.pwd)
  end
  
  # If a local ./gems dir is found, return it.
  def gem_dir
    if File.directory?(dir = default_gem_dir)
      dir
    end
  end
  
  def default_gem_dir
    File.join(working_dir, 'gems')
  end
  
end

##############################################################################
##############################################################################

module Merb
  
  class Dependencies < Thor
    
    attr_accessor :system, :local, :missing
    
    include MerbThorHelper
    
    default_method_options = {
      "--merb-root"            => :optional,  # the directory to operate on
      "--include-dependencies" => :boolean,   # install sub-dependencies
      "--stack"                => :boolean,   # install only stack dependencies
      "--no-stack"             => :boolean,   # install only non-stack dependencies
      "--config"               => :boolean,   # install dependencies from yaml config
      "--config-file"          => :optional,  # install from the specified yaml config
      "--force"                => :boolean,   # force the current operation
      "--version"              => :optional   # install specific version of framework
    }
    
    desc 'list [all|local|system|missing] [comp]', 'Show application dependencies'
    method_options default_method_options
    def list(filter = 'all', comp = nil)
      deps = comp ? Merb::Stack.select_component_dependencies(dependencies, comp) : dependencies
      self.system, self.local, self.missing = self.class.partition_dependencies(deps, gem_dir)
      case filter
      when 'all'
        message 'Installed system gem dependencies:'  unless system.empty? 
        display_gemspecs(system)
        message 'Installed local gem dependencies:'   unless local.empty? 
        display_gemspecs(local)
        error 'Missing gem dependencies:'             unless missing.empty? 
        display_dependencies(missing)
      when 'system'
        message 'Installed system gem dependencies:'  unless system.empty? 
        display_gemspecs(system)
      when 'local'
        message 'Installed local gem dependencies:'   unless local.empty? 
        display_gemspecs(local)
      when 'missing'
        error 'Missing gem dependencies:'             unless missing.empty? 
        display_dependencies(missing)
      else
        warning "Invalid listing filter '#{filter}'"
      end
    end
    
    # thor merb:dependencies:install stable merb-more
    # thor merb:dependencies:install stable missing
    
    desc 'install [stable|edge] [comp]', 'Install application dependencies'
    method_options default_method_options.merge("--dry-run" => :boolean)
    def install(strategy = 'stable', comp = nil)
      if self.respond_to?(method = :"#{strategy}_strategy", true)
        # When comp == 'missing' then filter on missing dependencies
        if only_missing = comp == 'missing'
          message "Preparing to install missing gems using #{strategy} strategy..."
          comp = nil
        else
          message "Preparing to install using #{strategy} strategy..."
        end
        
        # If comp given, filter on known stack components
        deps = comp ? Merb::Stack.select_component_dependencies(dependencies, comp) : dependencies
        self.system, self.local, self.missing = self.class.partition_dependencies(deps, gem_dir)
        
        # Only install currently missing gems (for comp == missing)
        if only_missing
          deps.reject! { |dep| not missing.include?(dep) }
        end
        
        if deps.empty?
          warning "No dependencies to install..."
        else
          puts "#{deps.length} dependencies to install..."
          # Clobber existing local dependencies
          clobber_dependencies!
        
          # Run the chosen strategy
          send(method, deps)
        end
        
        # Show current dependency info now that we're done
        puts # Seperate output
        list('all', comp)
      else
        warning "Invalid install strategy '#{strategy}'"
      end      
    end
    
    desc 'uninstall [comp]', 'Uninstall application dependencies'
    method_options default_method_options.merge("--dry-run" => :boolean)
    def uninstall(comp = nil)
      # If comp given, filter on known stack components
      deps = comp ? Merb::Stack.select_component_dependencies(dependencies, comp) : dependencies
      self.system, self.local, self.missing = self.class.partition_dependencies(deps, gem_dir)
      # Clobber existing local dependencies
      clobber_dependencies!
    end
    
    desc 'configure', 'Create a dependencies config file'
    method_options default_method_options
    def configure
      FileUtils.mkdir_p(config_dir) unless File.directory?(config_dir)
      config = YAML.dump(dependencies.map { |d| d.to_s })
      puts "#{config}\n"
      if File.exists?(config_file) && !options[:force]
        error "File already exists! Use --force to overwrite."
      else
        File.open(config_file, 'w') { |f| f.write config }
        success "Written #{config_file}:"
      end
    rescue  
      error "Failed to write to #{config_file}"
    end    
    
    ### Helper Methods
    
    def default_install_options
      { :install_dir => gem_dir, :ignore_dependencies => ignore_dependencies? }
    end
    
    def default_uninstall_options
      { :install_dir => gem_dir, :ignore => true, :executables => true }
    end
    
    def dry_run?
      options[:"dry-run"]
    end
    
    def ignore_dependencies?
      not options[:"include-dependencies"]
    end
    
    def dependencies
      if use_config?
        # Use preconfigured dependencies from yaml file
        deps = config_dependencies
      else
        # Extract dependencies from the current application
        deps = Merb::Stack.core_dependencies(gem_dir, ignore_dependencies?)
        deps += Merb::Dependencies.extract_dependencies(working_dir)
      end
      
      if options[:stack]
        # Limit to stack components only
        stack_components = Merb::Stack.components
        deps.reject! { |dep| not stack_components.include?(dep.name) }
      elsif options[:"no-stack"]
        # Limit to non-stack components
        stack_components = Merb::Stack.components
        deps.reject! { |dep| stack_components.include?(dep.name) }
      end
      
      if options[:version]
        # Handle specific version requirement for framework components
        version_req = ::Gem::Requirement.create("= #{options[:version]}")
        framework_components = Merb::Stack.framework_components
        deps.each do |dep| 
          if framework_components.include?(dep.name)
            dep.version_requirements = version_req
          end
        end
      end
            
      deps
    end
    
    def config_dependencies
      if File.exists?(config_file)
        self.class.parse_dependencies_yaml(File.read(config_file))
      else
        []
      end
    end
    
    def use_config?
      options[:config] || options[:"config-file"]
    end
    
    def config_file
      @config_file ||= begin
        options[:"config-file"] || File.join(working_dir, 'config', 'dependencies.yml')
      end
    end
    
    def config_dir
      File.dirname(config_file)
    end
    
    def display_gemspecs(gemspecs)
      gemspecs.each { |spec| puts "- #{spec.full_name}" }
    end
    
    def display_dependencies(dependencies)
      dependencies.each { |d| puts "- #{d.name} (#{d.version_requirements})" }
    end
    
    def install_dependency(dependency)
      v = dependency.version_requirements.to_s
      Merb::Gem.install(dependency.name, default_install_options.merge(:version => v))
    end
    
    def clobber_dependencies!
      if options[:force] && gem_dir && File.directory?(gem_dir)
        # Remove all existing local gems by clearing the gems directory
        if dry_run?
          note 'Clearing existing local gems...'
        else
          message 'Clearing existing local gems...'
          FileUtils.rm_rf(gem_dir) && FileUtils.mkdir_p(default_gem_dir)
        end
      elsif !local.empty? 
        # Uninstall all local versions of the gems to install
        if dry_run?
          note 'Uninstalling existing local gems:'
          local.each { |gemspec| note "Uninstalled #{gemspec.name}" }
        else
          message 'Uninstalling existing local gems:' 
          local.each do |gemspec|
            Merb::Gem.uninstall(gemspec.name, default_uninstall_options)
          end
        end
      end
    end
    
    ### Strategy handlers
    
    private
    
    def stable_strategy(deps)
      if core = deps.find { |d| d.name == 'merb-core' }
        if dry_run?
          note "Installing #{core.name}..."
        else
          install_dependency(core)
        end
      end
      
      deps.each do |dependency|
        next if dependency.name == 'merb-core'
        if dry_run?
          note "Installing #{dependency.name}..."
        else
          install_dependency(dependency)
        end        
      end
    end
    
    # def edge_strategy(deps)
    #   p deps
    # end
    
    ### Class Methods
    
    public
    
    # Extract application dependencies by querying the app directly.
    def self.extract_dependencies(merb_root)
      FileUtils.cd(merb_root) do
        cmd = ["require 'yaml';"]
        cmd << "dependencies = Merb::BootLoader::Dependencies.dependencies"
        cmd << "entries = dependencies.map { |d| d.to_s }"
        cmd << "puts YAML.dump(entries)"
        output = `merb -r "#{cmd.join("\n")}"`
        if index = (lines = output.split(/\n/)).index('--- ')
          yaml = lines.slice(index, lines.length - 1).join("\n")
          return parse_dependencies_yaml(yaml)
        end
      end
      return []
    end
    
    # Parse the basic YAML config data, and process Gem::Dependency output.
    # Formatting example: merb_helpers (>= 0.9.8, runtime)
    def self.parse_dependencies_yaml(yaml)
      dependencies = []
      entries = YAML.load(yaml) rescue []
      entries.each do |entry|
        if matches = entry.match(/^(\S+) \(([^,]+)?, ([^\)]+)\)/)
          name, version_req, type = matches.captures
          dependencies << ::Gem::Dependency.new(name, version_req, type.to_sym)
        else
          error "Invalid entry: #{entry}"
        end
      end
      dependencies
    end
    
    # Partition gems into system, local and missing gems
    def self.partition_dependencies(dependencies, gem_dir)
      system_specs, local_specs, missing_deps = [], [], []
      if gem_dir && File.directory?(gem_dir)
        gem_dir = File.expand_path(gem_dir)
        ::Gem.clear_paths; ::Gem.path.unshift(gem_dir)
        ::Gem.source_index.refresh!     
        dependencies.each do |dep|
          if gemspec = ::Gem.source_index.search(dep).last
            if gemspec.loaded_from.index(gem_dir) == 0
              local_specs  << gemspec
            else
              system_specs << gemspec
            end
          else
            missing_deps << dep
          end
        end
        ::Gem.clear_paths
      end
      [system_specs, local_specs, missing_deps]
    end
    
  end  
  
  class Stack < Thor
    
    MERB_CORE = %w[merb-core]
    MERB_MORE = %w[
      merb-action-args merb-assets merb-gen merb-haml
      merb-builder merb-mailer merb-parts merb-cache 
      merb-slices merb-jquery merb-helpers
    ]
    MERB_PLUGINS = %w[
      merb_activerecord merb_sequel merb_param_protection 
      merb_test_unit merb_stories merb_screw_unit merb_auth
    ]
    DM_CORE = %w[dm-core]
    DM_MORE = %w[merb_datamapper]
      
    desc 'list [stable|edge]', 'Show framework dependencies'
    def list
      
    end
    
    def install(strategy = 'none')
      
    end
    
    def uninstall
      
    end    
    
    # Find the latest merb-core and gather its dependencies.
    # We check for 0.9.8 as a minimum release version.
    def self.core_dependencies(gem_dir = nil, ignore_deps = false)
      @_core_dependencies ||= begin
        if gem_dir # add local gems to index
          ::Gem.clear_paths; ::Gem.path.unshift(gem_dir)
        end
        deps = []
        merb_core = ::Gem::Dependency.new('merb-core', '>= 0.9.8')
        if gemspec = ::Gem.source_index.search(merb_core).last
          deps << ::Gem::Dependency.new('merb-core', gemspec.version)
          deps += gemspec.dependencies unless ignore_deps
        end
        ::Gem.clear_paths if gem_dir # reset
        deps
      end
    end
    
    def self.framework_components
      %w[merb-core merb-more merb-plugins].inject([]) do |all, comp| 
        all + components(comp)
      end
    end
    
    def self.components(comp = nil)
      @_components ||= begin
        comps = {}
        comps["merb-core"]    = MERB_CORE
        comps["merb-more"]    = MERB_MORE
        comps["merb-plugins"] = MERB_PLUGINS
        
        comps["dm-core"]      = DM_CORE
        comps["dm-more"]      = DM_MORE
        comps
      end
      if comp
        @_components[comp]
      else
        comps = %w[merb-core merb-more merb-plugins dm-core dm-more]
        comps.inject([]) do |all, grp|
          all + (@_components[grp] || [])
        end
      end
    end
    
    def self.select_component_dependencies(dependencies, comp = nil)
      comps = components(comp)
      dependencies.select { |dep| comps.include?(dep.name) }
    end
    
  end
  
  class Util < Thor
    
  end
  
  #### RAW TASKS ####
  
  class Gem < Thor
    
    extend GemManagement
    
    def list
      
    end
    
    def install
      
    end
    
    def uninstall
      
    end
    
    
    # Install gem with some default options.
    def self.install(name, opts = {})
      defaults = {}
      defaults[:cache] = false unless opts[:install_dir]
      install_gem(name, defaults.merge(opts))
    end
    
    # Uninstall gem with some default options.
    def self.uninstall(name, opts = {})
      defaults = { :ignore => true, :executables => true }
      uninstall_gem(name, defaults.merge(opts))
    end
    
  end
  
  class Source < Thor
    
    def list
      
    end

    def install
      
    end
    
    def uninstall
      
    end
   
  end
  
end

module DataMapper
    
end