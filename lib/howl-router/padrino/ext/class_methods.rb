
class Howl
  module Padrino
    module ClassMethods
      CONTENT_TYPE_ALIASES = {:htm => :html} unless defined?(CONTENT_TYPE_ALIASES)
      ROUTE_PRIORITY       = {:high => 0, :normal => 1, :low => 2} unless defined?(ROUTE_PRIORITY)

      def router
        @router ||= ::Howl::Padrino::Core.new
        block_given? ? yield(@router) : @router
      end

      def compiled_router
        if @deferred_routes
          deferred_routes.each { |routes| routes.each { |(route, dest)| route.to(&dest) } }
          @deferred_routes = nil
        end
        router
      end

      def deferred_routes
        @deferred_routes ||= ROUTE_PRIORITY.map{[]}
      end

      def url(*args)
        params = args.extract_options!
        names, params_array = args.partition{|a| a.is_a?(Symbol)}
        name = names.join("_").to_sym
        if params.is_a?(Hash)
          params[:format] = params[:format].to_s unless params[:format].nil?
          params = value_to_param(params)
        end
        url = if params_array.empty?
                compiled_router.path(name, params)
              else
                compiled_router.path(name, *(params_array << params))
              end
        url[0,0] = conform_uri(uri_root) if defined?(uri_root)
        url[0,0] = conform_uri(ENV['RACK_BASE_URI']) if ENV['RACK_BASE_URI']
        url = "/" if url.blank?
        url
      rescue Howl::InvalidRouteException
        route_error = "route mapping for url(#{name.inspect}) could not be found!"
        raise ::Padrino::Routing::UnrecognizedException.new(route_error)
      end
      alias :url_for :url

      def recognize_path(path)
        responses = @router.recognize_path(path)
        [responses[0], responses[1]]
      end

      private

      def route(verb, path, *args, &block)
        options = case args.size
          when 2
            args.last.merge(:map => args.first)
          when 1
            map = args.shift if args.first.is_a?(String)
            if args.first.is_a?(Hash)
              map ? args.first.merge(:map => map) : args.first
            else
              {:map => map || args.first}
            end
          when 0
            {}
          else raise
        end

        route_options = options.dup
        route_options[:provides] = @_provides if @_provides

        if allow_disabled_csrf
          unless route_options[:csrf_protection] == false
            route_options[:csrf_protection] = true
          end
        end

        path, *route_options[:with] = path if path.is_a?(Array)
        action = path
        path, name, route_parents, options, route_options = *parse_route(path, route_options, verb)
        options.reverse_merge!(@_conditions) if @_conditions

        method_name = "#{verb} #{path}"
        unbound_method = generate_method(method_name, &block)

        block = block.arity != 0 ?
          proc {|a,p| unbound_method.bind(a).call(*p) } :
          proc {|a,p| unbound_method.bind(a).call }

        invoke_hook(:route_added, verb, path, block)

        # Howl route construction
        path[0, 0] = "/" if path == "(.:format)"
        route = router.add(verb.downcase.to_sym, path, route_options)
        route.name = name if name
        route.action = action
        priority_name = options.delete(:priority) || :normal
        priority = ROUTE_PRIORITY[priority_name] or raise("Priority #{priority_name} not recognized, try #{ROUTE_PRIORITY.keys.join(', ')}")
        route.cache = options.key?(:cache) ? options.delete(:cache) : @_cache
        route.parent = route_parents ? (route_parents.count == 1 ? route_parents.first : route_parents) : route_parents
        route.host = options.delete(:host) if options.key?(:host)
        route.user_agent = options.delete(:agent) if options.key?(:agent)
        if options.key?(:default_values)
          defaults = options.delete(:default_values)
          route.default_values = defaults if defaults
        end
        options.delete_if do |option, captures|
          if route.significant_variable_names.include?(option)
            route.capture[option] = Array(captures).first
            true
          end
        end

        # Add Sinatra conditions
        options.each {|o, a| route.respond_to?("#{o}=") ? route.send("#{o}=", a) : send(o, *a) }
        conditions, @conditions = @conditions, []
        route.custom_conditions.concat(conditions)

        invoke_hook(:padrino_route_added, route, verb, path, args, options, block)

        # Add Application defaults
        route.before_filters.concat(@filters[:before])
        route.after_filters.concat(@filters[:after])
        if @_controller
          route.use_layout = @layout
          route.controller = Array(@_controller)[0].to_s
        end

        deferred_routes[priority] << [route, block]

        route
      end

      def provides(*types)
        @_use_format = true
        condition do
          mime_types = types.map {|t| mime_type(t) }.compact
          url_format = params[:format].to_sym if params[:format]
          accepts = request.accept.map {|a| a.to_str }
          accepts = [] if accepts == ["*/*"]

          # per rfc2616-sec14:
          # Assume */* if no ACCEPT header is given.
          catch_all = (accepts.delete "*/*" || accepts.empty?)
          matching_types = accepts.empty? ? mime_types.slice(0,1) : (accepts & mime_types)
          if matching_types.empty? && types.include?(:any)
            matching_types = accepts
          end

          if !url_format && matching_types.first
            type = ::Rack::Mime::MIME_TYPES.find {|k, v| v == matching_types.first }[0].sub(/\./,'').to_sym
            accept_format = CONTENT_TYPE_ALIASES[type] || type
          elsif catch_all && !types.include?(:any)
            type = types.first
            accept_format = CONTENT_TYPE_ALIASES[type] || type
          end

          matched_format = types.include?(:any) ||
                           types.include?(accept_format) ||
                           types.include?(url_format) ||
                           ((!url_format) && request.accept.empty? && types.include?(:html))
          # per rfc2616-sec14:
          # answer with 406 if accept is given but types to not match any
          # provided type
          halt 406 if
            (!url_format && !accepts.empty? && !matched_format) ||
            (settings.respond_to?(:treat_format_as_accept) && settings.treat_format_as_accept && url_format && !matched_format)

          if matched_format
            @_content_type = url_format || accept_format || :html
            content_type(@_content_type, :charset => 'utf-8')
          end

          matched_format
        end
      end
    end
  end
end
