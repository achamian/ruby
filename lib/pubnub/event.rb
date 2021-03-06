module Pubnub
  module Event
    attr_reader :fired, :finished

    def initialize(options, app)
      @app              = app
      @origin           = options[:origin]           || app.env[:origin]
      @channel          = options[:channel]
      @channel_group    = options[:group]
      @message          = options[:message]
      @http_sync        = options[:http_sync]
      @callback         = options[:callback]
      @error_callback   = options[:error_callback]    || app.env[:error_callback]
      @presence_callback= options[:presence_callback] || app.env[:presence_callback]
      @connect_callback = options[:connect_callback]  || app.env[:connect_callback]
      @ssl              = options[:ssl]               || app.env[:ssl]

      @cipher_key       = app.env[:cipher_key]
      @secret_key       = app.env[:secret_key]
      @auth_key         = options[:auth_key]          || app.env[:auth_key]
      @publish_key      = app.env[:publish_key]
      @subscribe_key    = app.env[:subscribe_key]

      @write  = options[:write]
      @read   = options[:read]
      @manage = options[:manage]

      @response         = nil
      @timetoken        = app.env[:timetoken] || 0
      validate!
      @channel          = format_channels(@channel)
      @channel_group    = format_channel_group(options[:group], false)
      @original_channel = format_channels(@channel, false)
      Pubnub.logger.debug(:pubnub){"Event#initialize | Initialized #{self.class.to_s}"}
    end

    def secure_call(lambda, parameter)
      begin
        lambda.call parameter
      rescue => e
        Pubnub.logger.error(:pubnub){"Can't fire callback because: #{e}"}
      end
    end

    def fire(app)
      Pubnub.logger.debug(:pubnub){'Pubnub::Event#fire'}
      @fired = true
      Pubnub.logger.debug(:pubnub){'Event#fire'}
      setup_connection(app) unless connection_exist?(app)
      envelopes = start_event(app)
    end

    def send_request(app)
      Pubnub.logger.debug(:pubnub){'Pubnub::Event#send_request'}
      if app.disabled_persistent_connection?
        @response = Net::HTTP.get_response uri(app)
      else
        @response = get_connection(app).request(uri(app))
      end
    end

    def start_event(app, count = 0)
      begin
        @response = nil
        if count <= app.env[:max_retries]
          Pubnub.logger.debug(:pubnub){'Event#start_event | sending request'}
          Pubnub.logger.debug(:pubnub){"Event#start_event | tt: #{@timetoken}; ctt #{app.env[:timetoken]}"}
          @response = send_request(app)
        end

        error = response_error(@response, app)

        if ![error].flatten.include?(:json) || count > app.env[:max_retries] || app.env[:max_retries] == 0
          handle_response(@response, app, error)
        else
          start_event(app, count + 1)
        end
      rescue => e
        Pubnub.logger.error(:pubnub){e.inspect}
        sleep app.env[:retries_interval]
        if count <= app.env[:max_retries]
          start_event(app, count + 1)
        else
          Pubnub.logger.error(:pubnub){"Aborting #{self.class} event due to network errors and reaching max retries"}
          app.env[:subscribe_railgun].cancel if app.env[:subscribe_railgun]
          app.env[:subscribe_railgun] = nil
          false
        end
      end
    end

    def validate!
      if @allow_multiple_channels == true
        raise ArgumentError.new(:object => self, :message => 'Invalid channel(s) format! Should be type of: String, Symbol, or Array of both') unless valid_channel?(true)
      elsif @allow_multiple_channels == false
        raise ArgumentError.new(:object => self, :message => 'Invalid channel(s) format! Should be type of: String, Symbol') unless valid_channel?(false)
      end

      unless @doesnt_require_callback
        raise ArgumentError.new(:object => self, :message => 'Callback parameter is required while using async') if (!@http_sync && @callback.blank?)
      end

    end

    def finished?
      @finished ? true : false
    end

    def fired?
      @fired ? true : false
    end

    private

    def response_error(response, app)
      if Parser.valid_json?(response.body) && (200..206).include?(response.code.to_i)
        error = false
      elsif Parser.valid_json?(response.body) && !(200..206).include?(response.code.to_i)
        error = [:code]
      elsif !Parser.valid_json?(response.body) && (200..206).include?(response.code.to_i)
        error = [:json]
      else
        error = [:code, :json]
      end

      error
    end

    def handle_response(response, app, error)

      Pubnub.logger.debug(:pubnub){'Event#handle_response'}
      envelopes = format_envelopes(response, app, error)
      Pubnub.logger.debug(:pubnub){"Response: #{response.body}"} if (response && response.body)
      update_app_timetoken(envelopes, app)
      @finished = true
      fire_callbacks(envelopes,app)
      envelopes

    end

    def update_app_timetoken(envelopes, app)
      # stub
    end

    def fire_callbacks(envelopes, app)
      unless envelopes.blank?
        Pubnub.logger.debug(:pubnub){'Firing callbacks'}
        # EM.defer do
          envelopes.each do |envelope|
            secure_call(@callback, envelope) if envelope && !envelope.error && @callback && !envelope.timetoken_update
            #if envelope.timetoken_update || envelope.timetoken.to_i > app.env[:timetoken].to_i
            #  update_timetoken(app, envelope.timetoken)
            #end
          end
        secure_call(@error_callback, envelopes.first) if envelopes.first.error
        # end
      else
        Pubnub.logger.debug(:pubnub){'No envelopes for callback'}
      end
    end

    def update_timetoken(app, timetoken)
      @timetoken = timetoken.to_i
      app.update_timetoken(timetoken.to_i)
      Pubnub.logger.debug(:pubnub){"Updated timetoken to #{timetoken}"}
    end

    def add_common_data_to_envelopes(envelopes, response, app, error)
      Pubnub.logger.debug(:pubnub){'Event#add_common_data_to_envelopes'}

      envelopes.each do |envelope|
        envelope.response      = response.body
        envelope.object        = response
        envelope.status        = response.code.to_i
      end

      envelopes.last.last   = true if envelopes.last
      envelopes.first.first = true if envelopes.first

      envelopes = insert_errors(envelopes, error, app) if error

      envelopes
    end

    def insert_errors(envelopes, error_symbol, app)
      case error_symbol
        when [:json]
          error_message = '[0,"Invalid JSON in response."]'
          error         = JSONParseError.new(
              :app     => app,
              :message => error_message,
              :request => self.class,
              :response => @response.body,
              :error    => error_symbol
          )
        when [:code]
          error_message = '[0,"Non 2xx server response."]'
          error         = ResponseError.new(
              :app     => app,
              :message => error_message,
              :request => self.class,
              :response => @response.body,
              :error    => error_symbol
          )
        when [:code, :json]
          error_message = '[0,"Invalid JSON in response."]'
          error         = ResponseError.new(
              :app     => app,
              :message => error_message,
              :request => self.class,
              :response => @response.body,
              :error    => error_symbol
          )
        else
          error_message = '[0, "Unknown Error."]'
          error         = Error.new(
              :app     => app,
              :message => error_message,
              :request => self.class,
              :response => @response.body,
              :error    => error_symbol
          )
      end

      envelopes.first.error   = error
      envelopes.first.message = error_message
      envelopes.first.last = true

      [envelopes.first]
    end

    def uri(app)
      Pubnub.logger.debug(:pubnub){"#{self.class}#uri #{[origin(app), path(app), '?', params_hash_to_url_params(parameters(app))].join}"}
      URI [origin(app), path(app), '?', params_hash_to_url_params(parameters(app))].join
    end

    def origin(app)
      h = @ssl ? 'https://' : 'http://'
      h + @origin
    end

    def parameters(app)
      required = {
          :pnsdk => "PubNub-Ruby/#{Pubnub::VERSION}"
      }

      empty_if_blank = {
          :auth          => @auth_key,
          :uuid          => app.env[:uuid],
      }

      empty_if_blank.delete_if {|k, v| v.blank? }

      required.merge(empty_if_blank)
    end

  end

  module SingleEvent

    def fire(app)
      Pubnub.logger.debug(:pubnub){'Pubnub::SingleEvent#fire'}
      if @http_sync
        Pubnub.logger.debug(:pubnub){'Pubnub::SingleEvent#fire | Sync event!'}
        super(app)
      elsif app.async_events.include? self
        Pubnub.logger.debug(:pubnub){'Pubnub::SingleEvent#fire | Event already on list!'}
        super(app)
      else
        Pubnub.logger.debug(:pubnub){'Pubnub::SingleEvent#fire | Adding event to async_events'}
        app.async_events << self
        Pubnub.logger.debug(:pubnub){'Pubnub::SingleEvent#fire | Starting railgun'}
        app.start_railgun
      end
    end

    private

    def setup_connection(app)
      app.single_event_connections_pool[@origin] = new_connection(app)
    end

    def connection_exist?(app)
      !app.single_event_connections_pool[@origin].nil? && !app.single_event_connections_pool[@origin].nil?
    end

    def get_connection(app)
      app.single_event_connections_pool[@origin]
    end

    def new_connection(app)
      unless app.disabled_persistent_connection?
        connection = Net::HTTP::Persistent.new "pubnub_ruby_client_v#{Pubnub::VERSION}"
        connection.idle_timeout = app.env[:timeout]
        connection.read_timeout = app.env[:timeout]
        connection.proxy_from_env
        connection
      end
    end
  end

  module SubscribeEvent
    def initialize(options, app)
      super
    end

    def fire(app)
      begin
        Pubnub.logger.debug(:pubnub){'SubscribeEvent#fire'}
        if @http_sync
          Pubnub.logger.debug(:pubnub){'SubscribeEvent#fire sync'}
          if self.class == Pubnub::Subscribe && app.env[:heartbeat]
            app.heartbeat(:channel => @channel, :http_sync => true)
            envelopes = super
            @channel.each do |channel|
              app.leave(:channel => channel, :http_sync => true, :skip_remove => true, :force => true) unless (app.env[:subscriptions][@origin] && app.env[:subscriptions][@origin].get_channels.include(channel))
            end
          else
            envelopes = super
          end
          envelopes
        else
          Pubnub.logger.debug(:pubnub){'SubscribeEvent#fire async'}
          Pubnub.logger.debug(:pubnub){"Channel: #{@channel}"}
          setup_connection(app) unless connection_exist?(app)
          unless app.env[:subscriptions][@origin].blank?
            @channel.each do |channel|
              if app.env[:subscriptions][@origin].get_channels.include?(channel)
                @channel.delete(channel)
                Pubnub.logger.error(:pubnub){"Already subscribed to channel #{channel}, you have to leave that channel first"}
              end
            end

            @channel.each do |channel|
              Pubnub.logger.debug(:pubnub){'SubscribeEvent#add_channel | Adding channel'}
              app.env[:subscriptions][@origin].add_channel(channel, app)
            end

            @channel_group.each do |cg|
              if app.env[:subscriptions][@origin].get_channel_groups.include?(cg)
                @channel_group.delete(cg)
                Pubnub.logger.error(:pubnub){"Already subscribed to channel group #{cg}, you have to leave that channel first"}
              else
                app.env[:subscriptions][@origin].add_channel_group(cg, app)
              end
            end

            @wildcard_channel.each do |wc|
              if app.env[:subscriptions][@origin].get_wildcard_channels.include?(wc)
                @wildcard_channel.delete(wc)
                Pubnub.logger.error(:pubnub){"Already subscribed to wildcard channel #{wc}, you have to leave that channel first"}
              else
                app.env[:subscriptions][@origin].add_wildcard_channel(wc, app)
              end
            end

            if @channel.empty?
              false
            else
              app.start_respirator
              true
            end
          end

          if app.env[:subscriptions][@origin].nil?
            app.env[:subscriptions][@origin]                           = self            if app.env[:subscriptions][@origin].nil?
            app.env[:callbacks_pool]                                   = Hash.new        if app.env[:callbacks_pool].nil?
            app.env[:callbacks_pool][:channel]                         = Hash.new        if app.env[:callbacks_pool][:channel].nil?
            app.env[:callbacks_pool][:channel_group]                   = Hash.new        if app.env[:callbacks_pool][:channel_group].nil?
            app.env[:callbacks_pool][:wildcard_channel]                = Hash.new        if app.env[:callbacks_pool][:wildcard_channel].nil?
            app.env[:callbacks_pool][:channel][@origin]                = Hash.new        if app.env[:callbacks_pool][:channel][@origin].nil?
            app.env[:callbacks_pool][:channel_group][@origin]          = Hash.new        if app.env[:callbacks_pool][:channel_group][@origin].nil?
            app.env[:callbacks_pool][:wildcard_channel][@origin]       = Hash.new        if app.env[:callbacks_pool][:wildcard_channel][@origin].nil?
            app.env[:error_callbacks_pool]                             = Hash.new        if app.env[:error_callbacks_pool].nil?
            app.env[:error_callbacks_pool][:channel]                   = Hash.new        if app.env[:error_callbacks_pool][:channel].nil?
            app.env[:error_callbacks_pool][:channel][@origin]          = @error_callback if app.env[:error_callbacks_pool][:channel][@origin].nil?
            app.env[:error_callbacks_pool][:channel_group]             = Hash.new        if app.env[:error_callbacks_pool][:channel_group].nil?
            app.env[:error_callbacks_pool][:channel_group][@origin]    = @error_callback if app.env[:error_callbacks_pool][:channel_group][@origin].nil?
            app.env[:error_callbacks_pool][:wildcard_channel]          = Hash.new        if app.env[:error_callbacks_pool][:wildcard_channel].nil?
            app.env[:error_callbacks_pool][:wildcard_channel][@origin] = @error_callback if app.env[:error_callbacks_pool][:wildcard_channel][@origin].nil?

            @channel.each do |channel|
              app.env[:callbacks_pool][:channel][@origin][channel]            = Hash.new
              app.env[:callbacks_pool][:channel][@origin][channel][:callback] = @callback unless app.env[:callbacks_pool][:channel][@origin][:callback]
            end

            @channel_group.each do |channel_group|
              app.env[:callbacks_pool][:channel_group][@origin][channel_group]            = Hash.new
              app.env[:callbacks_pool][:channel_group][@origin][channel_group][:callback] = @callback unless app.env[:callbacks_pool][:channel_group][@origin][:callback]
            end

            @wildcard_channel.each do |wildcard_channel|
              app.env[:callbacks_pool][:wildcard_channel][@origin][wildcard_channel]             = Hash.new

              app.env[:callbacks_pool][:wildcard_channel][@origin][wildcard_channel][:callback]  = @callback unless app.env[:callbacks_pool][:wildcard_channel][@origin][:callback]
              app.env[:callbacks_pool][:wildcard_channel][@origin][wildcard_channel][:presence_callback] = @presence_callback unless app.env[:callbacks_pool][:wildcard_channel][@origin][wildcard_channel][:presence_callback]
            end

          else
            @channel.each do |channel|
              app.env[:callbacks_pool][:channel][@origin][channel] = Hash.new

              app.env[:callbacks_pool][:channel][@origin][channel][:callback]       = @callback       unless app.env[:callbacks_pool][:channel][@origin][:callback]
              app.env[:callbacks_pool][:channel][@origin][channel][:error_callback] = @error_callback unless app.env[:callbacks_pool][:channel][@origin][:error_callback]
            end

            @channel_group.each do |channel_group|
              app.env[:callbacks_pool][:channel_group][@origin][channel_group] = Hash.new

              app.env[:callbacks_pool][:channel_group][@origin][channel_group][:callback]       = @callback       unless app.env[:callbacks_pool][:channel_group][@origin][:callback]
              app.env[:callbacks_pool][:channel_group][@origin][channel_group][:error_callback] = @error_callback unless app.env[:callbacks_pool][:channel_group][@origin][:error_callback]
            end

            @wildcard_channel.each do |wildcard_channel|
              app.env[:callbacks_pool][:wildcard_channel][@origin][wildcard_channel] = Hash.new

              app.env[:callbacks_pool][:wildcard_channel][@origin][wildcard_channel][:callback]          = @callback       unless app.env[:callbacks_pool][:wildcard_channel][@origin][:callback]
              app.env[:callbacks_pool][:wildcard_channel][@origin][wildcard_channel][:error_callback]    = @error_callback unless app.env[:callbacks_pool][:wildcard_channel][@origin][:error_callback]
              app.env[:callbacks_pool][:wildcard_channel][@origin][wildcard_channel][:presence_callback] = @presence_callback unless app.env[:callbacks_pool][:wildcard_channel][@origin][wildcard_channel][:presence_callback]
            end
          end

          app.start_subscribe

        end
      rescue => error
        Pubnub.logger.error(:pubnub){error}
      end
    end

    def set_timetoken(timetoken)
      @timetoken = timetoken
    end

    def add_channel_group(cg, app)
      @channel_group << cg
      Pubnub.logger.debug(:pubnub){'SubscribeEvent#add_channel_group | Added channel'}
    end

    def add_channel(channel, app)
      @channel = @channel + format_channels(channel)
      Pubnub.logger.debug(:pubnub){'SubscribeEvent#add_channel | Added channel'}
    end

    def add_wildcard_channel(wc, app)
      @wildcard_channel << wc
      Pubnub.logger.debug(:pubnub){'SubscribeEvent#add_wildcard_channel | Added channel'}
    end

    def remove_channel(channel, app)
      @channel = @channel - format_channels(channel)
      Pubnub.logger.debug(:pubnub){'SubscribeEvent#remove_channel | Removed channel'}
      begin
        shutdown_subscribe(app) if @channel.empty? && @channel_group.empty? && @wildcard_channel.empty?
      rescue => e
        Pubnub.logger.error(:pubnub){e.message}
        Pubnub.logger.error(:pubnub){e.backtrace}
      end
    end

    def remove_channel_group(channel_group, app)
      @channel_group = @channel_group - format_channel_group(channel_group, false)
      Pubnub.logger.debug(:pubnub){'SubscribeEvent#remove_channel_group | Removed channel'}
      begin
        shutdown_subscribe(app) if @channel.empty? && @channel_group.empty? && @wildcard_channel.empty?
      rescue => e
        Pubnub.logger.error(:pubnub){e.message}
        Pubnub.logger.error(:pubnub){e.backtrace}
      end
    end

    def remove_wildcard_channel(wc, app)
      @wildcard_channel -= [wc]
      Pubnub.logger.debug(:pubnub){'SubscribeEvent#remove_wildcard_channel | Removed channel'}
      begin
        shutdown_subscribe(app) if @channel.empty? && @channel_group.empty? && @wildcard_channel.empty?
      rescue => e
        Pubnub.logger.error(:pubnub){e.message}
        Pubnub.logger.error(:pubnub){e.backtrace}
      end
    end

    def get_channels
      @channel
    end

    def get_channel_groups
      @channel_group
    end

    def get_wildcard_channels
      @wildcard_channel
    end

    private

    def parameters(app)
      parameters = super(app)
      parameters.merge!({:heartbeat => app.env[:heartbeat]}) if app.env[:heartbeat]
      parameters.merge!({'channel-group' => format_channel_group(@channel_group, true).join(',')}) unless @channel_group.blank?
      parameters.merge!({:state => encode_state(app.env[:state][@origin])}) if app.env[:state] && app.env[:state][@origin]
      parameters
    end

    def encode_state(state)
      URI.encode_www_form_component(state.to_json).gsub('+', '%20')
    end

    def update_app_timetoken(envelopes, app)
      Pubnub.logger.debug(:pubnub){'Event#update_app_timetoken'}
      envelopes.each do |envelope|
        if envelope.timetoken_update || envelope.timetoken.to_i > app.env[:timetoken].to_i
          update_timetoken(app, envelope.timetoken)
        end
      end
      app.env[:wait_for_response][@origin] = false unless @http_sync
    end

    def shutdown_subscribe(app)
      app.env[:subscriptions][@origin]  = nil
      app.env[:subscriptions].delete(@origin)
      app.env[:callbacks_pool][@origin] = nil
      app.env[:callbacks_pool].delete(@origin)
      app.subscribe_event_connections_pool[@origin].shutdown_in_all_threads
      app.subscribe_event_connections_pool[@origin] = nil
      app.subscribe_event_connections_pool.delete(@origin)
    end

    def fire_callbacks(envelopes, app)
      if @http_sync
        super
      else
        begin
          Pubnub.logger.debug(:pubnub){'Event#fire_callbacks async'}
          envelopes.each do |envelope|
            if group_envelope?(envelope, app) # WITH GROUP
              secure_call(
                  app.env[:callbacks_pool][:channel_group][@origin][envelope.channel_group][:callback],
                  envelope
              ) if !envelope.error && !envelope.timetoken_update
            elsif channel_envelope?(envelope, app) # CHANNEL SUBSCRIBE
              secure_call(
                  app.env[:callbacks_pool][:channel][@origin][encode_channel(envelope.channel)][:callback],
                  envelope
              ) if !envelope.error && !envelope.timetoken_update
            elsif wc_pnpres_envelope(envelope, app) # wildcard pnpres
              secure_call(
                  app.env[:callbacks_pool][:wildcard_channel][@origin][encode_channel(envelope.wildcard_channel)][:presence_callback],
                  envelope
              ) if !envelope.error && !envelope.timetoken_update
            elsif wc_envelope?(envelope, app) # wildcard
              secure_call(
                  app.env[:callbacks_pool][:wildcard_channel][@origin][encode_channel(envelope.wildcard_channel)][:callback],
                  envelope
              ) if !envelope.error && !envelope.timetoken_update
            end
          end
          Pubnub.logger.debug(:pubnub){'We can send next request now'}
          secure_call(
              app.env[:error_callbacks_pool][:channel][@origin],
              envelopes.first
          ) if envelopes.first.error && !envelopes.first.channel_group

          secure_call(
              app.env[:error_callbacks_pool][:channel_group][@origin],
              envelopes.first
          ) if envelopes.first.error &&  envelopes.first.channel_group

        rescue => error
          Pubnub.logger.error(:pubnub){error}
          Pubnub.logger.error(:pubnub){error.backtrace}
        end
      end unless envelopes.nil?

    end

    def group_envelope?(envelope, app)
      envelope.channel_group && app.env[:callbacks_pool][:channel_group][@origin][envelope.channel_group]
    rescue
      false
    end

    def channel_envelope?(envelope, app)
      app.env[:callbacks_pool][:channel][@origin][encode_channel(envelope.channel)]
    rescue
      false
    end

    def wc_pnpres_envelope(envelope, app)
      app.env[:callbacks_pool][:wildcard_channel][@origin][envelope.wildcard_channel][:presence_callback] && (envelope.channel.index('-pnpres') || envelope.wildcard_channel.index('-pnpres'))
    rescue
      false
    end

    def wc_envelope?(envelope, app)
      app.env[:callbacks_pool][:wildcard_channel][@origin][envelope.wildcard_channel][:callback]
    rescue
      false
    end

    def setup_connection(app)
      app.subscribe_event_connections_pool[@origin] = new_connection(app)
    end

    def connection_exist?(app)
      !app.subscribe_event_connections_pool[@origin].nil? && !app.subscribe_event_connections_pool[@origin].nil?
    end

    def get_connection(app)
      app.subscribe_event_connections_pool[@origin]
    end

    def path(app)
      path = "/subscribe/#{@subscribe_key}/#{channels_for_url(@channel + @wildcard_channel)}/0/#{@timetoken}".gsub(/\?/,'%3F')
    end

    def timetoken(parsed_response)
      parsed_response[1] if parsed_response.is_a? Array
    end

    def message(parsed_response, i, channel, app)
      if app.env[:cipher_key].blank? || channel.index('-pnpres')
        parsed_response.first[i]
      else
        pc = Crypto.new(app.env[:cipher_key])
        pc.decrypt(parsed_response.first[i])
      end
    end

    def format_envelopes(response, app, error)

      Pubnub.logger.debug(:pubnub){'Subscribe#format_envelopes'}

      parsed_response = Parser.parse_json(response.body) if Parser.valid_json?(response.body)

      Pubnub.logger.debug(:pubnub){'Subscribe#format_envelopes | Response parsed'}

      envelopes = Array.new
      if error
        Pubnub.logger.debug(:pubnub){'Subscribe#format_envelopes | Error'}
        envelopes << Envelope.new(
            {
                :channel           => @channel,
                :parsed_response   => parsed_response,
                :timetoken         => timetoken(parsed_response)
            },
            app
        )
      elsif parsed_response[0].empty?
        Pubnub.logger.debug(:pubnub){'Subscribe#format_envelopes | Timetoken'}
        envelopes << Envelope.new(
            {
                :channel           => @channel.first,
                :response_message  => parsed_response,
                :parsed_response   => parsed_response,
                :timetoken         => timetoken(parsed_response),
                :timetoken_update  => true
            },
            app
        )
      elsif parsed_response.length < 4
        Pubnub.logger.debug(:pubnub){'Subscribe#format_envelopes | Not timetoken update'}

        if parsed_response[2]
          channels = parsed_response[2].split(',')
        else
          channels = @channel
        end

        parsed_response[0].size.times do |i|
          if channels.size <= 1
            channel = channels.first
          else
            channel = channels[i]
          end
          Pubnub.logger.debug(:pubnub){"Subscribe#format_envelopes | Channel #{channel} created"}

          Pubnub.logger.debug(:pubnub){"#{parsed_response}"}

          envelopes << Envelope.new(
              {
                  :message           => message(parsed_response, i, channel, app),
                  :channel           => channel,
                  :response_message  => parsed_response,
                  :parsed_response   => parsed_response,
                  :timetoken         => timetoken(parsed_response)
              },
              app
          )

          Pubnub.logger.debug(:pubnub){'Subscribe#format_envelopes | Envelopes created'}

        end
      else
        Pubnub.logger.debug(:pubnub){'Subscribe#format_envelopes | Not timetoken update'}

        parsed_response[0].size.times do |i|
          channel       = parsed_response[3].split(',')[i]
          channel_group = parsed_response[2].split(',')[i]

          if channel_group.index('.*')
            wildcard_channel = channel_group
            channel_group = nil
          end

          Pubnub.logger.debug(:pubnub){"#{parsed_response}"}

          envelopes << Envelope.new(
              {
                  :message           => message(parsed_response, i, channel, app),
                  :channel           => channel,
                  :channel_group     => channel_group,
                  :wildcard_channel  => wildcard_channel,
                  :response_message  => parsed_response,
                  :parsed_response   => parsed_response,
                  :timetoken         => timetoken(parsed_response)
              },
              app
          )

          Pubnub.logger.debug(:pubnub){'Subscribe#format_envelopes | Envelopes created'}

        end
      end

      Pubnub.logger.debug(:pubnub){'Subscribe#format_envelopes | envelopes created'}

      envelopes = add_common_data_to_envelopes(envelopes, response, app, error)

      envelopes

    end

    def new_connection(app)
      unless app.disabled_persistent_connection?
        connection = Net::HTTP::Persistent.new "pubnub_ruby_client_v#{Pubnub::VERSION}"
        connection.idle_timeout   = app.env[:subscribe_timeout]
        connection.read_timeout   = app.env[:subscribe_timeout]
        connection.proxy_from_env
        connection
      end
    end
  end
end
