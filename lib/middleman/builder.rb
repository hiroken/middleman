require "thor"
require "thor/group"
require 'rack/test'
require 'find'

SHARED_SERVER_INST = Middleman.server.inst do
  set :environment, :build
end
SHARED_SERVER = SHARED_SERVER_INST.class

module Middleman
  module ThorActions
    def tilt_template(source, *args, &block)
      config = args.last.is_a?(Hash) ? args.pop : {}
      destination = args.first || source
      
      request_path = destination.sub(/^#{SHARED_SERVER_INST.build_dir}/, "")
      
      begin
        destination, request_path = SHARED_SERVER_INST.reroute_builder(destination, request_path)
        
        response = Middleman::Builder.shared_rack.get(request_path.gsub(/\s/, "%20"))
        create_file(destination, response.body, config) if response.status == 200
      rescue
        say_status :error, destination, :red
      end
    end
  end
  
  class Builder < Thor::Group
    include Thor::Actions
    include Middleman::ThorActions
    
    def self.shared_rack
      @shared_rack ||= begin
        mock = ::Rack::MockSession.new(SHARED_SERVER.to_rack_app)
        sess = ::Rack::Test::Session.new(mock)
        response = sess.get("__middleman__")
        sess
      end
    end
    
    class_option :relative, :type => :boolean, :aliases => "-r", :default => false, :desc => 'Override the config.rb file and force relative urls'
    class_option :glob, :type => :string, :aliases => "-g", :default => nil, :desc => 'Build a subset of the project'
    
    def initialize(*args)
      super
      
      if options.has_key?("relative") && options["relative"]
        SHARED_SERVER_INST.activate :relative_assets
      end
    end
    
    def source_paths
      @source_paths ||= [
        SHARED_SERVER_INST.root
      ]
    end
    
    def build_all_files
      self.class.shared_rack
      
      opts = { }
      opts[:glob]  = options["glob"]  if options.has_key?("glob")
      opts[:clean] = options["clean"] if options.has_key?("clean")
      
      action GlobAction.new(self, SHARED_SERVER_INST, opts)
      
      SHARED_SERVER_INST.run_hook :after_build, self
    end
  end
  
  class GlobAction < ::Thor::Actions::EmptyDirectory
    attr_reader :source

    def initialize(base, app, config={}, &block)
      @app         = app
      source       = @app.views
      @destination = @app.build_dir
      
      @source = File.expand_path(base.find_in_source_paths(source.to_s))
      
      super(base, destination, config)
    end

    def invoke!
      queue_current_paths if cleaning?
      execute!
      clean! if cleaning?
    end

    def revoke!
      execute!
    end

  protected
  
    def clean!
      files       = @cleaning_queue.select { |q| File.file? q }
      directories = @cleaning_queue.select { |q| File.directory? q }

      files.each do |f| 
        base.remove_file f, :force => true
      end

      directories = directories.sort_by {|d| d.length }.reverse!

      directories.each do |d|
        base.remove_file d, :force => true if directory_empty? d 
      end
    end
  
    def cleaning?
      @config.has_key?(:clean) && @config[:clean]
    end

    def directory_empty?(directory)
      Dir["#{directory}/*"].empty?
    end

    def queue_current_paths
      @cleaning_queue = []
      Find.find(@destination) do |path|
        next if path.match(/\/\./)
        unless path == destination
          @cleaning_queue << path.sub(@destination, destination[/([^\/]+?)$/])
        end
      end
    end
    
    def execute!
      sort_order = %w(.png .jpeg .jpg .gif .bmp .ico .woff .otf .ttf .eot .js .css)
      
      paths = @app.sitemap.all_paths.sort do |a, b|
        a_ext = File.extname(a)
        b_ext = File.extname(b)
        
        a_idx = sort_order.index(a_ext) || 100
        b_idx = sort_order.index(b_ext) || 100
        
        a_idx <=> b_idx
      end
      
      paths.each do |path|
        file_source = path
        file_destination = File.join(given_destination, file_source.gsub(source, '.'))
        file_destination.gsub!('/./', '/')
        
        if @app.sitemap.generic?(file_source)
          # no-op
        elsif @app.sitemap.proxied?(file_source)
          file_source = @app.sitemap.page(file_source).proxied_to
        elsif @app.sitemap.ignored?(file_source)
          next
        end
        
        @cleaning_queue.delete(file_destination) if cleaning?
        
        if @config[:glob]
          next unless File.fnmatch(@config[:glob], file_source)
        end
        
        base.tilt_template(file_source, file_destination, { :force => true })
      end
    end
  end
end