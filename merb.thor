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
  
  def info(*messages)
    puts messages.map { |msg| "\033[1;34m#{msg}\033[0m" }
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

      # Limit source index to install dir
      update_source_index(options[:install_dir]) if options[:install_dir]

      installer = Gem::DependencyInstaller.new(options.merge(:user_install => false))
      
      # Force-refresh certain gems by excluding them from the current index
      if refresh.respond_to?(:include?) && !refresh.empty?
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
  
  # Partition gems into system, local and missing gems
  def partition_dependencies(dependencies, gem_dir)
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
  
  attr_accessor :include_dependencies
  
  def self.included(base)
    base.send(:include, ColorfulMessages)
    base.extend ColorfulMessages
  end
    
  def display_gemspecs(gemspecs)
    gemspecs.each { |spec| puts "- #{spec.full_name}" }
  end
  
  def display_dependencies(dependencies)
    dependencies.each { |d| puts "- #{d.name} (#{d.version_requirements})" }
  end
  
  def default_install_options
    { :install_dir => gem_dir, :ignore_dependencies => ignore_dependencies? }
  end
  
  def default_uninstall_options
    { :install_dir => gem_dir, :ignore => true, :all => true, :executables => true }
  end
  
  def dry_run?
    options[:"dry-run"]
  end
  
  def ignore_dependencies?
    options[:"ignore-dependencies"] || !include_dependencies?
  end
  
  def include_dependencies?
    options[:"include-dependencies"] || self.include_dependencies
  end
  
  # The current working directory, or Merb app root (--merb-root option).
  def working_dir
    @_working_dir ||= File.expand_path(options['merb-root'] || Dir.pwd)
  end
  
  # We should have a ./src dir for local and system-wide management.
  def source_dir
    @_source_dir  ||= File.join(working_dir, 'src')
    create_if_missing(@_source_dir)
    @_source_dir
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
  
  # If we're in a Merb app, we can have a ./bin directory;
  # create it if it's not there.
  def bin_dir
    @_bin_dir ||= begin
      if gem_dir
        dir = File.join(working_dir, 'bin')
        create_if_missing(dir)
        dir
      end
    end
  end
  
  # Helper to create dir unless it exists.
  def create_if_missing(path)
    FileUtils.mkdir(path) unless File.exists?(path)
  end

  def ensure_bin_wrapper_for(*gems)
    Merb::Gem.ensure_bin_wrapper_for(gem_dir, bin_dir, *gems)
  end
  
  def local_gemspecs(directory = gem_dir)
    if File.directory?(specs_dir = File.join(directory, 'specifications'))
      Dir[File.join(specs_dir, '*.gemspec')].map do |gemspec_path|
        gemspec = Gem::Specification.load(gemspec_path)
        gemspec.loaded_from = gemspec_path
        gemspec
      end
    else
      []
    end
  end
  
end

##############################################################################
##############################################################################

module Merb
  
  class Dependencies < Thor
    
    attr_accessor :system, :local, :missing
    
    include MerbThorHelper
    
    global_method_options = {
      "--merb-root"            => :optional,  # the directory to operate on
      "--include-dependencies" => :boolean,   # gather sub-dependencies
      "--stack"                => :boolean,   # gather only stack dependencies
      "--no-stack"             => :boolean,   # gather only non-stack dependencies
      "--config"               => :boolean,   # gather dependencies from yaml config
      "--config-file"          => :optional,  # gather from the specified yaml config
      "--version"              => :optional   # gather specific version of framework
    }
    
    method_options global_method_options
    def initialize(*args); super; end
    
    # List application dependencies.
    #
    # By default all dependencies are listed, partitioned into system, local and
    # currently missing dependencies. The first argument allows you to filter
    # on any of the partitionings. A second argument can be used to filter on
    # a set of known components, like all merb-more gems for example.
    # 
    # Examples:
    #
    # merb:dependencies:list                                    # list all dependencies - the default
    # merb:dependencies:list local                              # list only local gems
    # merb:dependencies:list all merb-more                      # list only merb-more related dependencies
    # merb:dependencies:list --stack                            # list framework dependencies
    # merb:dependencies:list --no-stack                         # list 3rd party dependencies
    # merb:dependencies:list --config                           # list dependencies from the default config
    # merb:dependencies:list --config-file file.yml             # list from the specified config file
       
    desc 'list [all|local|system|missing] [comp]', 'Show application dependencies'
    def list(filter = 'all', comp = nil)
      deps = comp ? Merb::Stack.select_component_dependencies(dependencies, comp) : dependencies
      self.system, self.local, self.missing = Merb::Gem.partition_dependencies(deps, gem_dir)
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
    
    # Install application dependencies.
    #
    # By default all required dependencies are installed. The first argument 
    # specifies which strategy to use: stable or edge. A second argument can be 
    # used to filter on a set of known components.
    #
    # Existing dependencies will be clobbered; when :force => true then all gems
    # will be cleared first, otherwise only existing local dependencies of the
    # gems to be installed will be removed.
    # 
    # Examples:
    #
    # merb:dependencies:install                                 # install all dependencies using stable strategy
    # merb:dependencies:install stable --version 0.9.8          # install a specific version of the framework
    # merb:dependencies:install stable missing                  # install currently missing gems locally
    # merb:dependencies:install stable merb-more                # install only merb-more related dependencies
    # merb:dependencies:install stable --stack                  # install framework dependencies
    # merb:dependencies:install stable --no-stack               # install 3rd party dependencies
    # merb:dependencies:install stable --config                 # read dependencies from the default config
    # merb:dependencies:install stable --config-file file.yml   # read from the specified config file
    #
    # In addition to the options above, edge install uses the following: 
    #
    # merb:dependencies:install edge                            # install all dependencies using edge strategy
    # merb:dependencies:install edge --sources file.yml         # install edge from the specified git sources config
    
    desc 'install [stable|edge] [comp]', 'Install application dependencies'
    method_options "--dry-run" => :boolean, "--force" => :boolean, "--sources" => :optional
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
        self.system, self.local, self.missing = Merb::Gem.partition_dependencies(deps, gem_dir)
        
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
          
          # Add local binaries for the installed framework dependencies
          ensure_bin_wrapper_for(*Merb::Stack.framework_components)
        end
        
        # Show current dependency info now that we're done
        puts # Seperate output
        list('all', comp)
      else
        warning "Invalid install strategy '#{strategy}'"
        puts
        message "Please choose one of the following installation strategies: stable or edge:"
        puts "$ thor merb:dependencies:install stable"
        puts "$ thor merb:dependencies:install edge"
      end      
    end
    
    # Uninstall application dependencies.
    #
    # By default all required dependencies are installed. An optional argument 
    # can be used to filter on a set of known components.
    #
    # Existing dependencies will be clobbered; when :force => true then all gems
    # will be cleared , otherwise only existing local dependencies of the
    # matching component set will be removed.
    #
    # Examples:
    #
    # merb:dependencies:uninstall                               # uninstall all dependencies - the default
    # merb:dependencies:uninstall merb-more                     # uninstall merb-more related gems locally
    # merb:dependencies:uninstall --config                      # read dependencies from the default config
    
    desc 'uninstall [comp]', 'Uninstall application dependencies'
    method_options "--dry-run" => :boolean, "--force" => :boolean
    def uninstall(comp = nil)
      # If comp given, filter on known stack components
      deps = comp ? Merb::Stack.select_component_dependencies(dependencies, comp) : dependencies
      self.system, self.local, self.missing = Merb::Gem.partition_dependencies(deps, gem_dir)
      # Clobber existing local dependencies - based on self.local
      clobber_dependencies!
    end
    
    # This task should be executed as part of a deployment setup, where the 
    # deployment system runs this after the app has been installed.
    # Usually triggered by Capistrano, God...
    #
    # It will regenerate gems from the bundled gems cache for any gem that has 
    # C extensions - which need to be recompiled for the target deployment platform.
    #
    # Note: gems/cache should be in your SCM for this to work correctly.
    
    desc 'redeploy', 'Recreate any binary gems on the target deployment platform'
    method_options "--dry-run" => :boolean
    def redeploy
      require 'tempfile' # for Dir::tmpdir access
      if gem_dir && File.directory?(cache_dir = File.join(gem_dir, 'cache'))
        local_gemspecs.each do |gemspec|
          unless gemspec.extensions.empty?
            if File.exists?(gem_file = File.join(cache_dir, "#{gemspec.full_name}.gem"))
              gem_file_copy = File.join(Dir::tmpdir, File.basename(gem_file))
              if dry_run?
                note "Recreating #{gemspec.full_name}"
              else
                message "Recreating #{gemspec.full_name}"
                # Copy the gem to a temporary file, because otherwise RubyGems/FileUtils
                # will complain about copying identical files (same source/destination).
                FileUtils.cp(gem_file, gem_file_copy)
                Merb::Gem.install(gem_file_copy, :install_dir => gem_dir)
                File.delete(gem_file_copy)
              end
            end
          end
        end
      else
        error "No application local gems directory found"
      end
    end
    
    # Create a dependencies configuration file.
    #
    # A configuration yaml file will be created from the extracted application
    # dependencies. The format of the configuration is as follows:
    #
    # --- 
    # - merb-core (= 0.9.8, runtime)
    # - merb-slices (= 0.9.8, runtime)
    # 
    # This format is exactly the same as Gem::Dependency#to_s returns.
    #
    # Examples:
    #
    # merb:dependencies:configure --force                       # overwrite the default config file
    # merb:dependencies:configure --version 0.9.8               # configure specific framework version
    # merb:dependencies:configure --config-file file.yml        # write to the specified config file 
    
    desc 'configure [comp]', 'Create a dependencies config file'
    method_options "--dry-run" => :boolean, "--force" => :boolean
    def configure(comp = nil)
      # If comp given, filter on known stack components
      deps = comp ? Merb::Stack.select_component_dependencies(dependencies, comp) : dependencies
      config = YAML.dump(deps.map { |d| d.to_s })
      puts "#{config}\n"
      if File.exists?(config_file) && !options[:force]
        error "File already exists! Use --force to overwrite."
      else
        if dry_run?
          note "Written #{config_file}"
        else
          FileUtils.mkdir_p(config_dir) unless File.directory?(config_dir)
          File.open(config_file, 'w') { |f| f.write config }
          success "Written #{config_file}"
        end
      end
    rescue  
      error "Failed to write to #{config_file}"
    end 
    
    ### Helper Methods
    
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
    
    def edge_strategy(deps)
      if core = deps.find { |d| d.name == 'merb-core' }
        if dry_run?
          note "Installing #{core.name}..."
        else
          if install_dependency_from_source(core)
          elsif install_dependency(dependency)
            info "Installed #{core.name} from rubygems..."
          end
        end
      end
      
      deps.each do |dependency|
        next if dependency.name == 'merb-core'
        if dry_run?
          note "Installing #{dependency.name}..."
        else
          if install_dependency_from_source(dependency)
          elsif install_dependency(dependency)
            info "Installed #{dependency.name} from rubygems..."
          end
        end        
      end
    end
    
    def install_dependency_from_source(dependency)
      if repo_url = Merb::Source.repo(dependency.name, options[:sources])
        # A repository entry for this dependency exists
        repository_path = dependency.name
        repository_name = dependency.name
        repository_url  = repo_url       
      elsif (stack_name = Merb::Stack.lookup_component(dependency.name)) &&
        (repo_url = Merb::Source.repo(stack_name, options[:sources]))
        # A parent repository entry for this dependency exists
        puts "Found #{stack_name}/#{dependency.name} at #{repo_url}"
        repository_path = File.join(stack_name, dependency.name)
        repository_name = stack_name
        repository_url  = repo_url        
      end
      
      if repository_name && repository_url
        result = if File.directory?(repository_dir = File.join(source_dir, repository_name))
          message "Updating or branching #{repository_name}..."
          update(repository_name, repository_url)
        else
          message "Cloning #{repository_name} repository from #{repository_url}..."
          clone(repository_name, repository_url)
        end
        if result && File.directory?(gem_src_dir = File.join(source_dir, repository_path))
          begin
            Merb::Gem.install_gem_from_src(gem_src_dir, default_install_options)
            puts "Installed #{repository_path}"
            return true
          rescue => e
            error "TODO #{e.message}"
          end
        else
          error "TODO #{gem_src_dir}"
        end
      end
      return false
    end
    
    def clone(name, url)
      FileUtils.cd(source_dir) do
        Kernel.system("git clone --depth 1 #{url} #{name}")
      end
    rescue => e
      error "TODO #{e.message}"
    end
    
    def update(name, url)
      if File.directory?(repository_dir = File.join(source_dir, name))
        FileUtils.cd(repository_dir) do
          repos = existing_repos(name)
          fork_name = url[/.com\/+?(.+)\/.+\.git/u, 1]
          if url == repos["origin"]
            # Pull from the original repository - no branching needed
            info "Pulling from origin: #{url}"
            Kernel.system "git fetch; git checkout master; git rebase origin/master"
          elsif repos.values.include?(url) && fork_name
            # Update and switch to a remote branch for a particular github fork
            info "Switching to remote branch: #{fork_name}"
            Kernel.system "git checkout -b #{fork_name} #{fork_name}/master"   
            Kernel.system "git rebase #{fork_name}/master"
          elsif fork_name
            # Create a new remote branch for a particular github fork
            info "Adding a new remote branch: #{fork_name}"
            Kernel.system "git remote add -f #{fork_name} #{url}"
            Kernel.system "git checkout -b #{fork_name} #{fork_name}/master"
          else
            warning "No valid repository found for: #{name}"
          end
        end
        return true
      else
        warning "No valid repository found at: #{repository_dir}"
      end
    rescue => e
      error "TODO #{e.message}"
      return false
    end
    
    def existing_repos(name)
      repos = []
      FileUtils.cd(File.join(source_dir, name)) do
        repos = %x[git remote -v].split("\n").map { |branch| branch.split(/\s+/) }
      end
      Hash[*repos.flatten]
    end
    
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
    
  end  
  
  class Stack < Thor
    
    MERB_CORE = %w[extlib merb-core]
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
    
    attr_accessor :system, :local, :missing
    
    include MerbThorHelper
    
    global_method_options = {
      "--merb-root"            => :optional,  # the directory to operate on
      "--include-dependencies" => :boolean,   # gather sub-dependencies
      "--stack"                => :boolean,   # gather only stack dependencies
      "--no-stack"             => :boolean,   # gather only non-stack dependencies
      "--config"               => :boolean,   # gather dependencies from yaml config
      "--config-file"          => :optional,  # gather from the specified yaml config
      "--version"              => :optional   # gather specific version of framework
    }
    
    method_options global_method_options
    def initialize(*args); super; end
    
    def install
      
    end
    
    def uninstall
      
    end    
    
    def self.framework_components
      %w[merb-core merb-more merb-plugins].inject([]) do |all, comp| 
        all + components(comp)
      end
    end
    
    def self.component_sets
      @_component_sets ||= begin
        comps = {}
        comps["merb-core"]    = MERB_CORE
        comps["merb-more"]    = MERB_MORE
        comps["merb-plugins"] = MERB_PLUGINS
        
        comps["dm-core"]      = DM_CORE
        comps["dm-more"]      = DM_MORE
        comps
      end
    end
    
    def self.components(comp = nil)
      if comp
        component_sets[comp]
      else
        comps = %w[merb-core merb-more merb-plugins dm-core dm-more]
        comps.inject([]) do |all, grp|
          all + (component_sets[grp] || [])
        end
      end
    end
    
    def self.select_component_dependencies(dependencies, comp = nil)
      comps = components(comp) || []
      dependencies.select { |dep| comps.include?(dep.name) }
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
    
    def self.lookup_component(item)
      set_name = nil
      self.component_sets.find do |set, items| 
        items.include?(item) ? (set_name = set) : nil
      end
      set_name
    end
    
  end
  
  class Util < Thor
    
  end
  
  #### RAW TASKS ####
  
  class Gem < Thor
    
    include MerbThorHelper
    extend GemManagement
    
    attr_accessor :system, :local, :missing
    
    global_method_options = {
      "--merb-root"            => :optional,  # the directory to operate on
      "--version"              => :optional,  # gather specific version of gem
      "--ignore-dependencies"  => :boolean    # don't install sub-dependencies
    }
    
    method_options global_method_options
    def initialize(*args); super; end
    
    # List gems that match the specified criteria.
    #
    # By default all local gems are listed. When the first argument is 'all' the
    # list is partitioned into system an local gems; specify 'system' to show
    # only system gems. A second argument can be used to filter on a set of known
    # components, like all merb-more gems for example.
    # 
    # Examples:
    #
    # merb:gem:list                                    # list all local gems - the default
    # merb:gem:list all                                # list system and local gems
    # merb:gem:list system                             # list only system gems
    # merb:gem:list all merb-more                      # list only merb-more related gems
    # merb:gem:list --version 0.9.8                    # list gems that match the version    
       
    desc 'list [all|local|system] [comp]', 'Show installed gems'
    def list(filter = 'local', comp = nil)
      deps = comp ? Merb::Stack.select_component_dependencies(dependencies, comp) : dependencies
      self.system, self.local, self.missing = Merb::Gem.partition_dependencies(deps, gem_dir)
      case filter
      when 'all'
        message 'Installed system gems:'  unless system.empty? 
        display_gemspecs(system)
        message 'Installed local gems:'   unless local.empty? 
        display_gemspecs(local)
      when 'system'
        message 'Installed system gems:'  unless system.empty? 
        display_gemspecs(system)
      when 'local'
        message 'Installed local gems:'   unless local.empty? 
        display_gemspecs(local)
      else
        warning "Invalid listing filter '#{filter}'"
      end
    end
    
    # Install the specified gems.
    #
    # All arguments should be names of gems to install.
    #
    # When :force => true then any existing versions of the gems to be installed
    # will be uninstalled first. It's important to note that so-called meta-gems
    # or gems that exactly match a set of Merb::Stack.components will have their
    # sub-gems uninstalled too. For example, uninstalling merb-more will install
    # all contained gems: merb-action-args, merb-assets, merb-gen, ...
    # 
    # Examples:
    #
    # merb:gems:install merb-core merb-slices          # install all specified gems
    # merb:gems:install merb-core --version 0.9.8      # install a specific version of a gem
    # merb:gems:install merb-core --force              # uninstall then subsequently install the gem
    # merb:gems:install merb-core --cache              # try to install locally from system gems
    # merb:gems:install merb-core --binaries           # also install adapted bin wrapper
     
    desc 'install GEM_NAME [GEM_NAME, ...]', 'Install a gem from rubygems'
    method_options "--cache"     => :boolean,
                   "--binaries"  => :boolean,
                   "--dry-run"   => :boolean,
                   "--force"     => :boolean
    def install(*names)
      self.include_dependencies = true # deal with dependencies by default
      opts = { :version => options[:version], :cache => options[:cache] }
      current_gem = nil
      
      # uninstall existing gems of the ones we're going to install
      uninstall(*names) if options[:force]
      
      names.each do |gem_name|
        current_gem = gem_name      
        if dry_run?
          note "Installing #{current_gem}..."
        else
          message "Installing #{current_gem}..."
          self.class.install(gem_name, default_install_options.merge(opts))
          ensure_bin_wrapper_for(gem_name) if options[:binaries]
        end
      end
    rescue => e
      error "Failed to install #{current_gem ? current_gem : 'gem'} (#{e.message})"
    end
    
    # Uninstall the specified gems.
    #
    # By default all specified gems are uninstalled. It's important to note that 
    # so-called meta-gems or gems that match a set of Merb::Stack.components will 
    # have their sub-gems uninstalled too. For example, uninstalling merb-more 
    # will install all contained gems: merb-action-args, merb-assets, ...
    #
    # Existing dependencies will be clobbered; when :force => true then all gems
    # will be cleared , otherwise only existing local dependencies of the
    # matching component set will be removed.
    #
    # Examples:
    #
    # merb:gem:uninstall merb-core merb-slices         # uninstall all specified gems
    # merb:gems:install merb-core --version 0.9.8      # uninstall a specific version of a gem
    
    desc 'uninstall GEM_NAME [GEM_NAME, ...]', 'Unstall a gem'
    method_options "--dry-run" => :boolean
    def uninstall(*names)
      self.include_dependencies = true # deal with dependencies by default
      opts = { :version => options[:version] }
      current_gem = nil
      if dry_run?
        note "Uninstalling any existing gems of: #{names.join(', ')}"
      else
        message "Uninstalling any existing gems of: #{names.join(', ')}"
        names.each do |gem_name|
          current_gem = gem_name
          Merb::Gem.uninstall(gem_name, default_uninstall_options) rescue nil
          # if this gem is a meta-gem or a component set name, remove sub-gems
          (Merb::Stack.components(gem_name) || []).each do |comp|
            Merb::Gem.uninstall(comp, default_uninstall_options) rescue nil
          end
        end
      end 
    rescue => e
      error "Failed to uninstall #{current_gem ? current_gem : 'gem'} (#{e.message})"
    end
    
    private
    
    # Return dependencies for all installed gems; both system-wide and locally;
    # optionally filters on :version requirement.
    def dependencies
      version_req = if options[:version]
        ::Gem::Requirement.create(options[:version])
      else
        ::Gem::Requirement.default
      end
      if gem_dir
        ::Gem.clear_paths; ::Gem.path.unshift(gem_dir)
        ::Gem.source_index.refresh!
      end
      deps = []
      ::Gem.source_index.each do |fullname, gemspec| 
        if version_req.satisfied_by?(gemspec.version)
          deps << ::Gem::Dependency.new(gemspec.name, "= #{gemspec.version}")
        end
      end
      ::Gem.clear_paths if gem_dir
      deps.sort
    end
    
    public
    
    # Install gem with some default options.
    def self.install(name, options = {})
      defaults = {}
      defaults[:cache] = false unless opts[:install_dir]
      install_gem(name, defaults.merge(options))
    end
    
    # Uninstall gem with some default options.
    def self.uninstall(name, options = {})
      defaults = { :ignore => true, :executables => true }
      uninstall_gem(name, defaults.merge(options))
    end
    
  end
  
  class Source < Thor
    
    # Default Git repositories
    def self.default_repos
      @_default_repos ||= { 
        'merb-core'     => "git://github.com/wycats/merb-core.git",
        'merb-more'     => "git://github.com/wycats/merb-more.git",
        'merb-plugins'  => "git://github.com/wycats/merb-plugins.git",
        'extlib'        => "git://github.com/sam/extlib.git",
        'dm-core'       => "git://github.com/sam/dm-core.git",
        'dm-more'       => "git://github.com/sam/dm-more.git",
        'sequel'        => "git://github.com/wayneeseguin/sequel.git",
        'do'            => "git://github.com/sam/do.git",
        'thor'          => "git://github.com/wycats/thor.git",
        'minigems'      => "git://github.com/fabien/minigems.git"
      }
    end

    # Git repository sources - pass source_config option to load a yaml 
    # configuration file - defaults to ./config/git-sources.yml and
    # ~/.merb/git-sources.yml - which need to create yourself if desired. 
    #
    # Example of contents:
    #
    # merb-core: git://github.com/myfork/merb-core.git
    # merb-more: git://github.com/myfork/merb-more.git
    def self.repos(source_config = nil)
      source_config ||= begin
        local_config = File.join(Dir.pwd, 'config', 'git-sources.yml')
        user_config  = File.join(ENV["HOME"] || ENV["APPDATA"], '.merb', 'git-sources.yml')
        File.exists?(local_config) ? local_config : user_config
      end
      if source_config && File.exists?(source_config)
        default_repos.merge(YAML.load(File.read(source_config)))
      else
        default_repos
      end
    end
    
    def self.repo(name, source_config = nil)
      self.repos(source_config)[name]
    end
    
    def list
      
    end

    def install
      
    end
    
    def uninstall
      
    end
    
    def self.clone
      
    end
    
    def self.install
      
    end
    
    def self.uninstall
      
    end
       
  end
  
end

module DataMapper
    
end