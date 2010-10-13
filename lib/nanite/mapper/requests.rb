require "nanite/helpers/state_helper"

module Nanite
  class Mapper
    class Requests
      include AMQPHelper
      include Nanite::Helpers::StateHelper

      attr_reader :options, :amqp, :serializer, :mapper

      def initialize(options = {})
        @options = options
        @amqp = start_amqp(@options)
        @serializer = Serializer.new(@options[:format])
        @security = SecurityProvider.get
        @mapper = Nanite::Mapper.new(options)
        @mapper.run
      end

      def run
        setup_request_queue
      end

      def setup_request_queue
        handler = lambda do |msg|
          begin
            handle_request(serializer.load(msg))
          rescue Exception => e
            Nanite::Log.error("RECV [request] #{e.message}")
          end
        end

        requests_fanout = amqp.fanout('request', :durable => true)
        if shared_state?
          amqp.queue("request").bind(requests_fanout).subscribe(&handler)
        else
          amqp.queue("request-#{options[:identity]}", :exclusive => true).bind(requests_fanout).subscribe(&handler)
        end
      end

      # forward request coming from agent
      def handle_request(request)
        if @security.authorize_request(request)
          Nanite::Log.debug("RECV #{request.to_s}")
          case request
          when Push
            mapper.send_push(request)
          else
            intm_handler = lambda do |result, job|
              result = IntermediateMessage.new(request.token, job.request.from, mapper.identity, nil, result)
              forward_response(result, request.persistent)
            end
          
            result = Result.new(request.token, request.from, nil, mapper.identity)
            ok = mapper.send_request(request, :intermediate_handler => intm_handler) do |res|
              result.results = res
              forward_response(result, request.persistent)
            end
            
            if ok == false
              forward_response(result, request.persistent)
            end
          end
        else
          Nanite::Log.warn("RECV NOT AUTHORIZED #{request.to_s}")
        end
      end

      # forward response back to agent that originally made the request
      def forward_response(res, persistent)
        Nanite::Log.debug("SEND #{res.to_s([:to])}")
        amqp.queue(res.to).publish(serializer.dump(res), :persistent => persistent)
      end
 
    end
  end
end