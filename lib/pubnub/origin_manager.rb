module Pubnub
  class OriginManager
    attr_reader :last_failback_ping_start, :last_alive_ping_start, :dead_origins

    def initialize(app)
      @app  = app

      @http                    = app.env[:ssl] ? 'https://' : 'http://'
      @ping_interval           = app.env[:origin_heartbeat_interval]
      @timeout                 = app.env[:non_subscribe_timeout]
      @max_retries             = app.env[:origin_heartbeat_max_retries]

      @dead_origins  = []
    end

    def start_current_origin_manager
      $logger.debug('Pubnub') { 'Starting ORIGIN MANAGER' }

      failures = 0

      EM.add_periodic_timer(@ping_interval) do
        @last_alive_ping_start = ::Time.now
        begin
          current_origin = @app.env[:origins_pool].first
          $logger.debug('Pubnub') { "Pinging #{current_origin + '/time/0'}" }


          if origin_online?(current_origin)
            failures = 0
          else
            failures += 1
          end

          if failures > @max_retries
            failures = 0
            set_origin_offline(current_origin)
            restart_subscription
            start_failback_manager unless failback_manager_running?
          end

        rescue => e
          $logger.error('Pubnub') { "#{e} #{e.backtrace}" }
        end unless @app.env[:origins_pool].empty?
      end
    end

    def start_failback_manager
      $logger.debug('Pubnub') { 'Starting FAILBACK ORIGIN MANAGER' }

      successes = 0
      @failback_manager = EM.add_periodic_timer(@app.env[:origin_heartbeat_interval]) do
        @last_failback_ping_start = ::Time.now
        begin
          dead_origin_to_test = @dead_origins.last

          if dead_origin_to_test != nil # Timer could fire again before cancelled

            $logger.debug('Pubnub') { "Pinging dead origin #{dead_origin_to_test + '/time/0'}" }
            uri_to_test = URI.parse(@http + dead_origin_to_test + '/time/0')

            $logger.debug('Pubnub') { "Origin manager: failback manager #{dead_origin_to_test}" }

            if alive_and_valid?(uri_to_test)
              $logger.warn('Pubnub') { "Origin manager: #{dead_origin_to_test} is online, adding success"}
              successes += 1
            else
              $logger.warn('Pubnub') { "Origin manager: #{dead_origin_to_test} is offline"}
              successes = 0
            end

            if successes == @max_retries
              successes = 0
              set_origin_online(dead_origin_to_test)
              restart_subscription
              if @dead_origins.empty?
                @failback_manager.cancel
              end
            end
          else
            @failback_manager.cancel
          end

        rescue => e
          $logger.error('Pubnub') { "#{e} #{e.backtrace}" }
        end
      end
    end

    def failback_manager_running?
      if @failback_manager && @failback_manager.instance_variable_get(:@cancelled)
        true
      else
        false
      end
    end

    private

    def origin_online?(origin)
      uri_to_test = URI.parse(@http + origin + '/time/0')

      if alive_and_valid?(uri_to_test)
        $logger.debug('Pubnub') { "Origin manager: #{origin} is online" }
         true
      else
         false
      end

    end

    def restart_subscription
      $logger.warn('Pubnub') { 'Restarting subscription' }
      @app.start_subscribe(true)
    end

    def set_origin_offline(origin)
      @app.env[:origins_pool].delete_if { |o| o == origin }
      @dead_origins << origin
      $logger.debug('Pubnub') { "Marked origin as offline.Online origins:#{@app.env[:origins_pool].join("")}Offline origins:#{@dead_origins.join("")}" }
    end

    def set_origin_online(origin)
      @dead_origins.delete_if { |o| o == origin }
      @app.env[:origins_pool].unshift(origin)
      $logger.debug('Pubnub') { "Marked origin as online.Online origins:#{@app.env[:origins_pool].join("")}Offline origins:#{@dead_origins.join("")}" }
    end

    def alive_and_valid?(uri)
      begin
        response = Net::HTTP.start(uri.host, uri.port) do |http|
          request = Net::HTTP::Get.new uri
          http.read_timeout = @timeout
          http.request request
        end
        response.is_a?(Net::HTTPSuccess) && Parser.valid_json?(response.body) ? true : false

      rescue Errno::ECONNREFUSED
        false
      rescue => e
        $logger.error('Pubnub'){ "#{e.inspect}" }
      end
    end
  end
end
