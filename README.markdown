# Instructions

To see an overview of the basic tasks run **thor -T**. Add *--all* to see all tasks, including the more low-level ones.

# Basic tasks

## merb:dependencies:*

The Dependencies tasks will install dependencies based on actual application
dependencies. For this, the application is queried for any dependencies.
All operations will be performed within this context.

### List application dependencies.

By default all dependencies are listed, partitioned into system, local and
currently missing dependencies. The first argument allows you to filter
on any of the partitionings. A second argument can be used to filter on
a set of known components, like all merb-more gems for example.

#### Examples:

- merb:dependencies:list                                    # list all dependencies - the default
- merb:dependencies:list local                              # list only local gems
- merb:dependencies:list all merb-more                      # list only merb-more related dependencies
- merb:dependencies:list --stack                            # list framework dependencies
- merb:dependencies:list --no-stack                         # list 3rd party dependencies
- merb:dependencies:list --config                           # list dependencies from the default config
- merb:dependencies:list --config-file file.yml             # list from the specified config file
  
### Install application dependencies.

By default all required dependencies are installed. The first argument 
specifies which strategy to use: stable or edge. A second argument can be 
used to filter on a set of known components.

Existing dependencies will be clobbered; when :force => true then all gems
will be cleared first, otherwise only existing local dependencies of the
gems to be installed will be removed.

#### Examples:

- merb:dependencies:install                                 # install all dependencies using stable strategy
- merb:dependencies:install stable --version 0.9.8          # install a specific version of the framework
- merb:dependencies:install stable missing                  # install currently missing gems locally
- merb:dependencies:install stable merb-more                # install only merb-more related dependencies
- merb:dependencies:install stable --stack                  # install framework dependencies
- merb:dependencies:install stable --no-stack               # install 3rd party dependencies
- merb:dependencies:install stable --config                 # read dependencies from the default config
- merb:dependencies:install stable --config-file file.yml   # read from the specified config file

In addition to the options above, edge install uses the following: 

- merb:dependencies:install edge                            # install all dependencies using edge strategy
- merb:dependencies:install edge --sources file.yml         # install edge from the specified git sources config
      
### Uninstall application dependencies.

By default all required dependencies are installed. An optional argument 
can be used to filter on a set of known components.

Existing dependencies will be clobbered; when :force => true then all gems
will be cleared, otherwise only existing local dependencies of the
matching component set will be removed.

#### Examples:

- merb:dependencies:uninstall                               # uninstall all dependencies - the default
- merb:dependencies:uninstall merb-more                     # uninstall merb-more related gems locally
- merb:dependencies:uninstall --config                      # read dependencies from the default config

### Recreate binary gems on the current platform.

This task should be executed as part of a deployment setup, where the 
deployment system runs this after the app has been installed.
Usually triggered by Capistrano, God...

It will regenerate gems from the bundled gems cache for any gem that has 
C extensions - which need to be recompiled for the target deployment platform.

Note: gems/cache should be in your SCM for this to work correctly.

#### Examples:

merb:dependencies:redeploy

### Create a dependencies configuration file.

A configuration yaml file will be created from the extracted application
dependencies. The format of the configuration is as follows:

<code>
--- 
- merb-core (= 0.9.8, runtime)
- merb-slices (= 0.9.8, runtime)
</code>

This format is exactly the same as Gem::Dependency#to_s returns.

#### Examples:

- merb:dependencies:configure --force                       # overwrite the default config file
- merb:dependencies:configure --version 0.9.8               # configure specific framework version
- merb:dependencies:configure --config-file file.yml        # write to the specified config file 
   
## merb:stack:*
  
### List components and their dependencies.

#### Examples:

- merb:stack:list                                           # list all components
- merb:stack:list merb-more                                 # list all dependencies of merb-more

### Install stack components or individual gems - from stable rubygems by default.

See also: Merb::Dependencies#install and Merb::Dependencies#install_dependencies

#### Examples:

- merb:stack:install                                        # install the default merb stack
- merb:stack:install basics                                 # install a basic set of dependencies
- merb:stack:install merb-core                              # install merb-core from stable
- merb:stack:install merb-more --edge                       # install merb-core from edge
- merb:stack:install merb-core thor merb-slices             # install the specified gems
              
### Uninstall stack components or individual gems.

See also: Merb::Dependencies#uninstall

#### Examples:

- merb:stack:uninstall                                      # uninstall the default merb stack
- merb:stack:uninstall merb-more                            # uninstall merb-more
- merb:stack:uninstall merb-core thor merb-slices           # uninstall the specified gems
    
## merb:tasks:*

### Find the latest merb-core and gather its dependencies.

We check for 0.9.8 as a minimum release version.

#### Examples:

- merb:tasks:version

### Show merb.thor version information

- merb:tasks:version                                        # show the current version info
- merb:tasks:version --info                                 # show extended version info

### Update merb.thor tasks from remotely available version

- merb:tasks:update                                        # update merb.thor
- merb:tasks:update --force                                # force-update merb.thor
- merb:tasks:update --dry-run                              # show version info only
    
***

# Low-level tasks

## merb:gem:*

### List gems that match the specified criteria.

By default all local gems are listed. When the first argument is 'all' the
list is partitioned into system an local gems; specify 'system' to show
only system gems. A second argument can be used to filter on a set of known
components, like all merb-more gems for example.

#### Examples:

- merb:gem:list                                    # list all local gems - the default
- merb:gem:list all                                # list system and local gems
- merb:gem:list system                             # list only system gems
- merb:gem:list all merb-more                      # list only merb-more related gems
- merb:gem:list --version 0.9.8                    # list gems that match the version    
  
### Install the specified gems.

All arguments should be names of gems to install.

When :force => true then any existing versions of the gems to be installed
will be uninstalled first. It's important to note that so-called meta-gems
or gems that exactly match a set of Merb::Stack.components will have their
sub-gems uninstalled too. For example, uninstalling merb-more will install
all contained gems: merb-action-args, merb-assets, merb-gen, ...

#### Examples:

- merb:gem:install merb-core merb-slices          # install all specified gems
- merb:gem:install merb-core --version 0.9.8      # install a specific version of a gem
- merb:gem:install merb-core --force              # uninstall then subsequently install the gem
- merb:gem:install merb-core --cache              # try to install locally from system gems
- merb:gem:install merb-core --binaries           # also install adapted bin wrapper

### Uninstall the specified gems.

By default all specified gems are uninstalled. It's important to note that 
so-called meta-gems or gems that match a set of Merb::Stack.components will 
have their sub-gems uninstalled too. For example, uninstalling merb-more 
will install all contained gems: merb-action-args, merb-assets, ...

Existing dependencies will be clobbered; when :force => true then all gems
will be cleared, otherwise only existing local dependencies of the
matching component set will be removed.

#### Examples:

- merb:gem:uninstall merb-core merb-slices        # uninstall all specified gems
- merb:gem:uninstall merb-core --version 0.9.8    # uninstall a specific version of a gem

## merb:source:*

### List source repositories, of either local or known sources.

#### Examples:

- merb:source:list                                   # list all local sources
- merb:source:list available                         # list all known sources
  
### Install the specified gems.

All arguments should be names of gems to install.

When :force => true then any existing versions of the gems to be installed
will be uninstalled first. It's important to note that so-called meta-gems
or gems that exactly match a set of Merb::Stack.components will have their
sub-gems uninstalled too. For example, uninstalling merb-more will install
all contained gems: merb-action-args, merb-assets, merb-gen, ...

#### Examples:

- merb:source:install merb-core merb-slices          # install all specified gems
- merb:source:install merb-core --force              # uninstall then subsequently install the gem
- merb:source:install merb-core --wipe               # clear repo then install the gem
- merb:source:install merb-core --binaries           # also install adapted bin wrapper
    
### Uninstall the specified gems.

By default all specified gems are uninstalled. It's important to note that 
so-called meta-gems or gems that match a set of Merb::Stack.components will 
have their sub-gems uninstalled too. For example, uninstalling merb-more 
will install all contained gems: merb-action-args, merb-assets, ...

Existing dependencies will be clobbered; when :force => true then all gems
will be cleared, otherwise only existing local dependencies of the
matching component set will be removed. Additionally when :wipe => true, 
the matching git repositories will be removed from the source directory.

#### Examples:

- merb:source:uninstall merb-core merb-slices       # uninstall all specified gems
- merb:source:uninstall merb-core --wipe            # force-uninstall a gem and clear repo
    
### Update the specified source repositories.

The arguments can be actual repository names (from Merb::Source.repos)
or names of known merb stack gems. If the repo doesn't exist already,
it will be created and cloned.

- merb:source:pull merb-core                         # update source of specified gem
- merb:source:pull merb-slices                       # implicitly updates merb-more

### Clone a git repository into ./src. 

The repository can be a direct git url or a known -named- repository.

#### Examples:

- merb:source:clone merb-core 
- merb:source:clone dm-core awesome-repo
- merb:source:clone dm-core --sources ./path/to/sources.yml
- merb:source:clone git://github.com/sam/dm-core.git
  
Git repository sources - pass source_config option to load a yaml 
configuration file - defaults to ./config/git-sources.yml and
~/.merb/git-sources.yml - which you need to create yourself. 

Example of contents:

<code>
merb-core: git://github.com/myfork/merb-core.git
merb-more: git://github.com/myfork/merb-more.git
</code>
