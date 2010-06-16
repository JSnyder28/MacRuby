# User customizable variables.
# These variables can be set from the command line. Example:
#    $ rake framework_instdir=~/Library/Frameworks sym_instdir=~/bin

class Builder
  def self.options
    @options ||= {}
  end

  def self.option(name, default)
    options[name] = default

    if val = ENV[name]
      block_given? ? yield(val) : val
    else
      default
    end
  end
end

b = Builder

ARCHS =
  if s = ENV['RC_ARCHS']
    $stderr.puts "Getting archs from RC_ARCHS!"
    s.strip.split(/\s+/)
  else
    b.option('archs', `arch`.include?('ppc') ? 'ppc' : %w{i386 x86_64}) { |x| x.split(',') }
  end

llvm_default_path = '/usr/local'
if `sw_vers -productVersion`.strip.to_f >= 10.7 and File.exist?('/AppleInternal')
  $stderr.puts "Welcome bleeding-edge adventurer!"
  llvm_default_path = '/Developer/usr/local'
  ENV['LLVM_TOT'] = '1'
  #ENV['LLVM_PRE_TOT'] = '1'
end

RUBY_INSTALL_NAME = b.option('ruby_install_name', 'macruby')
RUBY_SO_NAME = b.option('ruby_so_name', RUBY_INSTALL_NAME)
LLVM_PATH = b.option('llvm_path', llvm_default_path)
FRAMEWORK_NAME = b.option('framework_name', 'MacRuby')
FRAMEWORK_INSTDIR = b.option('framework_instdir', '/Library/Frameworks')
SYM_INSTDIR = b.option('sym_instdir', '/usr/local')
NO_WARN_BUILD = !b.option('allow_build_warnings', false)
ENABLE_STATIC_LIBRARY = b.option('enable_static_library', 'no') { 'yes' }
ENABLE_DEBUG_LOGGING = b.option('enable_debug_logging', true) { |x| x == 'true' }
SIMULTANEOUS_JOBS = b.option('jobs', 1) { |x| x.to_i }
COMPILE_STDLIB = b.option('compile_stdlib', true) { |x| x == 'true' }
OPTZ_LEVEL = b.option('optz_level', 3) { |x| x.to_i }

default_CC = '/usr/bin/gcc-4.2'
unless File.exist?(default_CC)
  default_CC = '/usr/bin/gcc'
end
CC = b.option('CC', default_CC)

default_CXX = '/usr/bin/g++-4.2'
unless File.exist?(default_CXX)
  default_CXX = '/usr/bin/g++'
end
CXX = b.option('CXX', default_CXX)

# Everything below this comment should *not* be modified.

if ENV['build_as_embeddable']
  $stderr.puts "The 'build_as_embeddable' build configuration has been removed because it is no longer necessary. To package a full version of MacRuby inside your application, please use `macrake deploy` for HotCocoa apps and the `Embed MacRuby` target for Xcode apps."
  exit 1
end

verbose(true)

if `sw_vers -productVersion`.strip < '10.5.6'
  $stderr.puts "Sorry, your environment is not supported. MacRuby requires Mac OS X 10.5.6 or higher." 
  exit 1
end

if `arch`.include?('ppc')
  $stderr.puts "You appear to be using a PowerPC machine. MacRuby's primary architectures are Intel 32-bit and 64-bit (i386 and x86_64). Consequently, PowerPC support may be lacking some features."
end

LLVM_CONFIG = File.join(LLVM_PATH, 'bin/llvm-config')
unless File.exist?(LLVM_CONFIG)
  $stderr.puts "The llvm-config executable was not located as #{LLVM_CONFIG}. Please make sure LLVM is correctly installed on your machine and pass the llvm_config option to rake if necessary."
  exit 1
end

if OPTZ_LEVEL < 0 || OPTZ_LEVEL > 3
  $stderr.puts "Incorrect optimization level: #{OPTZ_LEVEL}"
  exit 1
end

version_h = File.read('version.h')
NEW_RUBY_VERSION = version_h.scan(/#\s*define\s+RUBY_VERSION\s+\"([^"]+)\"/)[0][0]
unless defined?(MACRUBY_VERSION)
  MACRUBY_VERSION = version_h.scan(/#\s*define\s+MACRUBY_VERSION\s+\"(.*)\"/)[0][0]
end
INSTALL_VERSION = b.option('install_version', MACRUBY_VERSION)

uname_release_number = (ENV['UNAME_RELEASE'] or `uname -r`.scan(/^(\d+)\.\d+\.(\d+)/)[0].join('.'))
NEW_RUBY_PLATFORM = 'universal-darwin' + uname_release_number

FRAMEWORK_PATH = File.join(FRAMEWORK_INSTDIR, FRAMEWORK_NAME + '.framework')
FRAMEWORK_VERSION = File.join(FRAMEWORK_PATH, 'Versions', INSTALL_VERSION)
FRAMEWORK_USR = File.join(FRAMEWORK_VERSION, 'usr')
FRAMEWORK_USR_LIB = File.join(FRAMEWORK_USR, 'lib')
FRAMEWORK_USR_LIB_RUBY = File.join(FRAMEWORK_USR_LIB, 'ruby')

RUBY_LIB = File.join(FRAMEWORK_USR_LIB_RUBY, NEW_RUBY_VERSION)
RUBY_ARCHLIB = File.join(RUBY_LIB, NEW_RUBY_PLATFORM)
RUBY_SITE_LIB = File.join(FRAMEWORK_USR_LIB_RUBY, 'site_ruby')
RUBY_SITE_LIB2 = File.join(RUBY_SITE_LIB, NEW_RUBY_VERSION)
RUBY_SITE_ARCHLIB = File.join(RUBY_SITE_LIB2, NEW_RUBY_PLATFORM)
RUBY_VENDOR_LIB = File.join(FRAMEWORK_USR_LIB_RUBY, 'vendor_ruby')
RUBY_VENDOR_LIB2 = File.join(RUBY_VENDOR_LIB, NEW_RUBY_VERSION)
RUBY_VENDOR_ARCHLIB = File.join(RUBY_VENDOR_LIB2, NEW_RUBY_PLATFORM)

INSTALL_NAME = File.join(FRAMEWORK_USR_LIB, 'lib' + RUBY_SO_NAME + '.dylib')
ARCHFLAGS = ARCHS.map { |a| '-arch ' + a }.join(' ')
LLVM_MODULES = "core jit nativecodegen bitwriter bitreader ipo"
EXPORTED_SYMBOLS_LIST = "./exported_symbols_list"

OPTZFLAG = "-O#{OPTZ_LEVEL}"
STATIC_FLAGS = "-DMACRUBY_STATIC"
CFLAGS = "-std=c99 -I. -I./include #{ARCHFLAGS} -fno-common -pipe -g -Wall -fexceptions #{OPTZFLAG}"
CFLAGS << " -Wno-deprecated-declarations -Werror" if NO_WARN_BUILD
OBJC_CFLAGS = CFLAGS + " -fobjc-gc-only"
CFLAGS_STATIC = "#{CFLAGS} #{STATIC_FLAGS}"
CXXFLAGS_STATIC = "-I. -I./include -g -Wall #{ARCHFLAGS}"
CXXFLAGS_STATIC << " -Wno-deprecated-declarations -Werror" if NO_WARN_BUILD
CXXFLAGS = CXXFLAGS_STATIC + ' ' + `#{LLVM_CONFIG} --cxxflags #{LLVM_MODULES}`.sub(/-DNDEBUG/, '').sub(/-fno-exceptions/, '').sub(/-Wcast-qual/, '').strip
CXXFLAGS.sub!(/-O\d/, OPTZFLAG)
CXXFLAGS << " -fno-rtti" unless CXXFLAGS.index("-fno-rtti")
CXXFLAGS << " -DLLVM_TOT" if ENV['LLVM_TOT']
CXXFLAGS << " -DLLVM_PRE_TOT" if ENV['LLVM_PRE_TOT']
CXXFLAGS_STATIC << " #{OPTZFLAG} -fno-rtti #{STATIC_FLAGS}"
LDFLAGS_STATIC = "-lpthread -ldl -lxml2 -lobjc -lauto -licucore -framework Foundation"
LDFLAGS = LDFLAGS_STATIC + ' ' + `#{LLVM_CONFIG} --ldflags --libs #{LLVM_MODULES}`.strip.gsub(/\n/, '')
DLDFLAGS = "-dynamiclib -undefined suppress -flat_namespace -install_name #{INSTALL_NAME} -current_version #{MACRUBY_VERSION} -compatibility_version #{MACRUBY_VERSION} -exported_symbols_list #{EXPORTED_SYMBOLS_LIST}"
OBJC_CFLAGS_STATIC = "#{OBJC_CFLAGS} #{STATIC_FLAGS}"

if `sw_vers -productVersion`.to_f <= 10.6
  CFLAGS << " -I./icu-1060"
  CFLAGS_STATIC << " -I./icu-1060"
  CXXFLAGS << " -I./icu-1060"
  CXXFLAGS_STATIC << " -I./icu-1060"
  OBJC_CFLAGS << " -I./icu-1060"
  OBJC_CFLAGS_STATIC << " -I./icu-1060"
else
  if !File.exist?('/usr/local/include/unicode')
    $stderr.puts "Cannot locate ICU headers for this version of Mac OS X."
    exit 1
  end
end

OBJS_CFLAGS = {
  'dispatcher' => '-x objective-c++', # compile as Objective-C++.
  'bs' => '-I/usr/include/libxml2'    # need to access libxml2
}

# We monkey-patch the method that Rake uses to display the tasks so we can add
# the build options.
require 'rake'
module Rake
  class Application
    def formatted_macruby_options
      Builder.options.sort_by { |name, _| name }.map do |name, default|
        default = default.join(',') if default.is_a?(Array)
        "        #{name.ljust(30)} \"#{default}\""
      end.join("\n")
    end
    
    alias_method :display_tasks_and_comments_without_macruby_options, :display_tasks_and_comments
    
    def display_tasks_and_comments
      display_tasks_and_comments_without_macruby_options
      puts %{
  To change any of the default build options, use the rake build task
  of choice with any of these following option-value pairs:

    Usage: $ rake [task] [option=value, ...]

      #{'Option:'.ljust(30)} Default value:

#{formatted_macruby_options}

    Example:

      $ rake all archs="i386,ppc" framework_instdir="~/Library/Frameworks"

}
    end
  end
end
