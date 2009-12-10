require 'rack/mount'
require 'forwardable'

module ActionDispatch
  module Routing
    class RouteSet #:nodoc:
      NotFound = lambda { |env|
        raise ActionController::RoutingError, "No route matches #{env['PATH_INFO'].inspect} with #{env.inspect}"
      }

      PARAMETERS_KEY = 'action_dispatch.request.path_parameters'

      class Dispatcher
        def initialize(options = {})
          defaults = options[:defaults]
          @glob_param = options.delete(:glob)
        end

        def call(env)
          params = env[PARAMETERS_KEY]
          merge_default_action!(params)
          split_glob_param!(params) if @glob_param
          params.each do |key, value|
            if value.is_a?(String)
              value = value.dup.force_encoding(Encoding::BINARY) if value.respond_to?(:force_encoding)
              params[key] = URI.unescape(value)
            end
          end

          unless controller = controller(params)
            return [417, {}, []]
          end

          if env['action_controller.recognize']
            [200, {}, params]
          else
            controller.action(params[:action]).call(env)
          end
        end

        private
          def controller(params)
            if params && params.has_key?(:controller)
              controller = "#{params[:controller].camelize}Controller"
              ActiveSupport::Inflector.constantize(controller)
            end
          rescue NameError
            nil
          end

          def merge_default_action!(params)
            params[:action] ||= 'index'
          end

          def split_glob_param!(params)
            params[@glob_param] = params[@glob_param].split('/').map { |v| URI.unescape(v) }
          end
      end


      # A NamedRouteCollection instance is a collection of named routes, and also
      # maintains an anonymous module that can be used to install helpers for the
      # named routes.
      class NamedRouteCollection #:nodoc:
        include Enumerable
        attr_reader :routes, :helpers

        def initialize
          clear!
        end

        def clear!
          @routes = {}
          @helpers = []

          @module ||= Module.new
          @module.instance_methods.each do |selector|
            @module.class_eval { remove_method selector }
          end
        end

        def add(name, route)
          routes[name.to_sym] = route
          define_named_route_methods(name, route)
        end

        def get(name)
          routes[name.to_sym]
        end

        alias []=   add
        alias []    get
        alias clear clear!

        def each
          routes.each { |name, route| yield name, route }
          self
        end

        def names
          routes.keys
        end

        def length
          routes.length
        end

        def reset!
          old_routes = routes.dup
          clear!
          old_routes.each do |name, route|
            add(name, route)
          end
        end

        def install(destinations = [ActionController::Base, ActionView::Base], regenerate = false)
          reset! if regenerate
          Array(destinations).each do |dest|
            dest.__send__(:include, @module)
          end
        end

        private
          def url_helper_name(name, kind = :url)
            :"#{name}_#{kind}"
          end

          def hash_access_name(name, kind = :url)
            :"hash_for_#{name}_#{kind}"
          end

          def define_named_route_methods(name, route)
            {:url => {:only_path => false}, :path => {:only_path => true}}.each do |kind, opts|
              hash = route.defaults.merge(:use_route => name).merge(opts)
              define_hash_access route, name, kind, hash
              define_url_helper route, name, kind, hash
            end
          end

          def named_helper_module_eval(code, *args)
            @module.module_eval(code, *args)
          end

          def define_hash_access(route, name, kind, options)
            selector = hash_access_name(name, kind)
            named_helper_module_eval <<-end_eval # We use module_eval to avoid leaks
              def #{selector}(options = nil)                                      # def hash_for_users_url(options = nil)
                options ? #{options.inspect}.merge(options) : #{options.inspect}  #   options ? {:only_path=>false}.merge(options) : {:only_path=>false}
              end                                                                 # end
              protected :#{selector}                                              # protected :hash_for_users_url
            end_eval
            helpers << selector
          end

          def define_url_helper(route, name, kind, options)
            selector = url_helper_name(name, kind)
            # The segment keys used for positional parameters

            hash_access_method = hash_access_name(name, kind)

            # allow ordered parameters to be associated with corresponding
            # dynamic segments, so you can do
            #
            #   foo_url(bar, baz, bang)
            #
            # instead of
            #
            #   foo_url(:bar => bar, :baz => baz, :bang => bang)
            #
            # Also allow options hash, so you can do
            #
            #   foo_url(bar, baz, bang, :sort_by => 'baz')
            #
            named_helper_module_eval <<-end_eval # We use module_eval to avoid leaks
              def #{selector}(*args)                                                        # def users_url(*args)
                                                                                            #
                opts = if args.empty? || Hash === args.first                                #   opts = if args.empty? || Hash === args.first
                  args.first || {}                                                          #     args.first || {}
                else                                                                        #   else
                  options = args.extract_options!                                           #     options = args.extract_options!
                  args = args.zip(#{route.segment_keys.inspect}).inject({}) do |h, (v, k)|  #     args = args.zip([]).inject({}) do |h, (v, k)|
                    h[k] = v                                                                #       h[k] = v
                    h                                                                       #       h
                  end                                                                       #     end
                  options.merge(args)                                                       #     options.merge(args)
                end                                                                         #   end
                                                                                            #
                url_for(#{hash_access_method}(opts))                                        #   url_for(hash_for_users_url(opts))
                                                                                            #
              end                                                                           # end
              #Add an alias to support the now deprecated formatted_* URL.                  # #Add an alias to support the now deprecated formatted_* URL.
              def formatted_#{selector}(*args)                                              # def formatted_users_url(*args)
                ActiveSupport::Deprecation.warn(                                            #   ActiveSupport::Deprecation.warn(
                  "formatted_#{selector}() has been deprecated. " +                         #     "formatted_users_url() has been deprecated. " +
                  "Please pass format to the standard " +                                   #     "Please pass format to the standard " +
                  "#{selector} method instead.", caller)                                    #     "users_url method instead.", caller)
                #{selector}(*args)                                                          #   users_url(*args)
              end                                                                           # end
              protected :#{selector}                                                        # protected :users_url
            end_eval
            helpers << selector
          end
      end

      attr_accessor :routes, :named_routes, :configuration_files, :controller_paths

      def initialize
        self.configuration_files = []
        self.controller_paths = []

        self.routes = []
        self.named_routes = NamedRouteCollection.new

        clear!
      end

      def draw(&block)
        clear!

        mapper = Mapper.new(self)
        if block.arity == 1
          mapper.instance_exec(DeprecatedMapper.new(self), &block)
        else
          mapper.instance_exec(&block)
        end

        @set.add_route(NotFound)
        install_helpers
        @set.freeze
      end

      def clear!
        routes.clear
        named_routes.clear
        @set = ::Rack::Mount::RouteSet.new(:parameters_key => PARAMETERS_KEY)
      end

      def install_helpers(destinations = [ActionController::Base, ActionView::Base], regenerate_code = false)
        Array(destinations).each { |d| d.module_eval { include Helpers } }
        named_routes.install(destinations, regenerate_code)
      end

      def empty?
        routes.empty?
      end

      def add_configuration_file(path)
        self.configuration_files << path
      end

      # Deprecated accessor
      def configuration_file=(path)
        add_configuration_file(path)
      end

      # Deprecated accessor
      def configuration_file
        configuration_files
      end

      def load!
        # Clear the controller cache so we may discover new ones
        @controller_constraints = nil

        load_routes!
      end

      # reload! will always force a reload whereas load checks the timestamp first
      alias reload! load!

      def reload
        if configuration_files.any? && @routes_last_modified
          if routes_changed_at == @routes_last_modified
            return # routes didn't change, don't reload
          else
            @routes_last_modified = routes_changed_at
          end
        end

        load!
      end

      def load_routes!
        if configuration_files.any?
          configuration_files.each { |config| load(config) }
          @routes_last_modified = routes_changed_at
        else
          draw do |map|
            map.connect ":controller/:action/:id"
          end
        end
      end

      def routes_changed_at
        routes_changed_at = nil

        configuration_files.each do |config|
          config_changed_at = File.stat(config).mtime

          if routes_changed_at.nil? || config_changed_at > routes_changed_at
            routes_changed_at = config_changed_at
          end
        end

        routes_changed_at
      end

      CONTROLLER_REGEXP = /[_a-zA-Z0-9]+/

      def controller_constraints
        @controller_constraints ||= begin
          source = controller_namespaces.map { |ns| "#{Regexp.escape(ns)}/#{CONTROLLER_REGEXP.source}" }
          source << CONTROLLER_REGEXP.source
          Regexp.compile(source.sort.reverse.join('|'))
        end
      end

      def controller_namespaces
        namespaces = Set.new

        # Find any nested controllers already in memory
        ActionController::Base.subclasses.each do |klass|
          controller_name = klass.underscore
          namespaces << controller_name.split('/')[0...-1].join('/')
        end

        # Find namespaces in controllers/ directory
        controller_paths.each do |load_path|
          load_path = File.expand_path(load_path)
          Dir["#{load_path}/**/*_controller.rb"].collect do |path|
            namespaces << File.dirname(path).sub(/#{load_path}\/?/, '')
          end
        end

        namespaces.delete('')
        namespaces
      end

      def add_route(app, conditions = {}, requirements = {}, defaults = {}, name = nil)
        route = Route.new(app, conditions, requirements, defaults, name)
        @set.add_route(*route)
        named_routes[name] = route if name
        routes << route
        route
      end

      def options_as_params(options)
        # If an explicit :controller was given, always make :action explicit
        # too, so that action expiry works as expected for things like
        #
        #   generate({:controller => 'content'}, {:controller => 'content', :action => 'show'})
        #
        # (the above is from the unit tests). In the above case, because the
        # controller was explicitly given, but no action, the action is implied to
        # be "index", not the recalled action of "show".
        #
        # great fun, eh?

        options_as_params = options.clone
        options_as_params[:action] ||= 'index' if options[:controller]
        options_as_params[:action] = options_as_params[:action].to_s if options_as_params[:action]
        options_as_params
      end

      def build_expiry(options, recall)
        recall.inject({}) do |expiry, (key, recalled_value)|
          expiry[key] = (options.key?(key) && options[key].to_param != recalled_value.to_param)
          expiry
        end
      end

      # Generate the path indicated by the arguments, and return an array of
      # the keys that were not used to generate it.
      def extra_keys(options, recall={})
        generate_extras(options, recall).last
      end

      def generate_extras(options, recall={})
        generate(options, recall, :generate_extras)
      end

      def generate(options, recall = {}, method = :generate)
        options, recall = options.dup, recall.dup
        named_route = options.delete(:use_route)

        options = options_as_params(options)
        expire_on = build_expiry(options, recall)

        recall[:action] ||= 'index' if options[:controller] || recall[:controller]

        if recall[:controller] && (!options.has_key?(:controller) || options[:controller] == recall[:controller])
          options[:controller] = recall.delete(:controller)

          if recall[:action] && (!options.has_key?(:action) || options[:action] == recall[:action])
            options[:action] = recall.delete(:action)

            if recall[:id] && (!options.has_key?(:id) || options[:id] == recall[:id])
              options[:id] = recall.delete(:id)
            end
          end
        end

        options[:controller] = options[:controller].to_s if options[:controller]

        if !named_route && expire_on[:controller] && options[:controller] && options[:controller][0] != ?/
          old_parts = recall[:controller].split('/')
          new_parts = options[:controller].split('/')
          parts = old_parts[0..-(new_parts.length + 1)] + new_parts
          options[:controller] = parts.join('/')
        end

        options[:controller] = options[:controller][1..-1] if options[:controller] && options[:controller][0] == ?/

        merged = options.merge(recall)
        if options.has_key?(:action) && options[:action].nil?
          options.delete(:action)
          recall[:action] = 'index'
        end
        recall[:action] = options.delete(:action) if options[:action] == 'index'

        opts = {}
        opts[:parameterize] = lambda { |name, value|
          if name == :controller
            value
          elsif value.is_a?(Array)
            value.map { |v| Rack::Mount::Utils.escape_uri(v.to_param) }.join('/')
          else
            Rack::Mount::Utils.escape_uri(value.to_param)
          end
        }

        unless result = @set.generate(:path_info, named_route, options, recall, opts)
          raise ActionController::RoutingError, "No route matches #{options.inspect}"
        end

        uri, params = result
        params.each do |k, v|
          if v
            params[k] = v
          else
            params.delete(k)
          end
        end

        uri << "?#{params.to_query}" if uri && params.any?
        path = uri

        if path && method == :generate_extras
          uri = URI(path)
          extras = uri.query ?
            Rack::Utils.parse_nested_query(uri.query).keys.map { |k| k.to_sym } :
            []
          [uri.path, extras]
        elsif path
          path
        else
          raise ActionController::RoutingError, "No route matches #{options.inspect}"
        end
      rescue Rack::Mount::RoutingError
        raise ActionController::RoutingError, "No route matches #{options.inspect}"
      end

      def call(env)
        @set.call(env)
      rescue ActionController::RoutingError => e
        raise e if env['action_controller.rescue_error'] == false

        method, path = env['REQUEST_METHOD'].downcase.to_sym, env['PATH_INFO']

        # Route was not recognized. Try to find out why (maybe wrong verb).
        allows = HTTP_METHODS.select { |verb|
          begin
            recognize_path(path, {:method => verb}, false)
          rescue ActionController::RoutingError
            nil
          end
        }

        if !HTTP_METHODS.include?(method)
          raise ActionController::NotImplemented.new(*allows)
        elsif !allows.empty?
          raise ActionController::MethodNotAllowed.new(*allows)
        else
          raise e
        end
      end

      def recognize(request)
        params = recognize_path(request.path, extract_request_environment(request))
        request.path_parameters = params.with_indifferent_access
        "#{params[:controller].to_s.camelize}Controller".constantize
      end

      def recognize_path(path, environment = {}, rescue_error = true)
        method = (environment[:method] || "GET").to_s.upcase

        begin
          env = Rack::MockRequest.env_for(path, {:method => method})
        rescue URI::InvalidURIError => e
          raise ActionController::RoutingError, e.message
        end

        env['action_controller.recognize'] = true
        env['action_controller.rescue_error'] = rescue_error
        status, headers, body = call(env)
        body
      end

      # Subclasses and plugins may override this method to extract further attributes
      # from the request, for use by route conditions and such.
      def extract_request_environment(request)
        { :method => request.method }
      end
    end
  end
end
