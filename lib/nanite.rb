require 'rubygems'
require 'amqp'
require 'mq'
$:.unshift File.dirname(__FILE__)
require 'nanite/resource'
require 'nanite/result'
require 'nanite/op'
require 'nanite/answer'
require 'nanite/reducer'
require 'nanite/dispatcher'

module Nanite

  class DeleteOneNanite
    attr_accessor :nanite
    def initialize(nanite)
      @nanite = nanite
    end
  end
  
  class Register
    attr_accessor :name, :resources
    def initialize(name, resources)
      @name = name
      @resources = resources
    end
  end
  
  
  class AddOneNanite
    attr_accessor :nanite, :resources
    def initialize(nanite, resources)
      @nanite = nanite
      @resources = resources
    end
  end
  
  class MapperState
    attr_accessor :nanites
    def initialize(nanites)
      @nanites = nanites
    end
  end  
  
  class MapperStateRequest
  end
  
  class Ping
    attr_accessor :token, :from
    def initialize(token, from)
      @token = token
      @from = from
    end
  end
  
  class Pong
    attr_accessor :token
    def initialize(ping)
      @token = ping.token
    end
  end
  
  class << self
    attr_accessor :identity
    
    attr_accessor :default_resources, :last_ping, :ping_time
    
    def root
      @root ||= File.expand_path(File.dirname(__FILE__))
    end
    
    def op(type, payload, *resources, &blk)
      token = Nanite.gen_token
      op = Nanite::Op.new(type, payload, *resources)
      Nanite.mapper.route(op) do |answer|
        Nanite.callbacks[token] = blk if blk
        Nanite.reducer.watch_for(answer)
        Nanite.pending[token] = answer.token
      end
      token
    end
    
    def send_ping
      tok = Nanite.gen_token
      ping = Nanite::Ping.new(tok, Nanite.identity)
      Nanite.amq.topic('heartbeat').publish(Marshal.dump(ping), :key => 'nanite.pings')
    end
    
    def run_event_loop(threaded = true)
      runner = proc do
        case Nanite.identity
        when 'client'
          require 'readline'
          Thread.new{
            while l = Readline.readline('>> ')
              unless l.nil? or l.strip.empty?
                Readline::HISTORY.push(l)
                eval l
              end
            end
          }
        when 'merb'
            
        when 'shoes'
              
        else  
          Nanite::Dispatcher.register(GemRunner.new)
          Nanite::Dispatcher.register(Mock.new)
        end
        
        puts "registering"
        reg = Nanite::Register.new(Nanite.identity, Nanite::Dispatcher.all_resources)
        Nanite.amq.topic('registration').publish(Marshal.dump(reg), :key => 'nanite.register')
        
        EM.add_periodic_timer(60) do
          unless Time.now - Nanite.last_ping < 45
            reg = Nanite::Register.new(Nanite.identity, Nanite::Dispatcher.all_resources)
            Nanite.amq.topic('registration').publish(Marshal.dump(reg), :key => 'nanite.register')
          end
        end  
                
        EM.add_periodic_timer(30) do
          send_ping
        end
        
        Nanite.amq.queue(Nanite.identity, :exclusive => true).subscribe{ |msg|
          Nanite::Dispatcher.handle(Marshal.load(msg))
        }
      end
      if threaded
        Thread.new { 
          until EM.reactor_running?
            sleep 0.01
          end
          runner.call 
        }
      else
        runner.call 
      end      
    end  
    
    
    def reducer
      @reducer ||= Nanite::Reducer.new
    end
    
    def mapper
      Thread.current[:mapper] ||= MQ.new.rpc('mapper')
    end  
    
    def amq
      Thread.current[:mq] ||= MQ.new
    end
    
    def pending
      @pending ||= {}
    end
    
    def callbacks
      @callbacks ||= {}
    end
    
    def results
      @results ||= {}
    end
    
    def gen_token
      values = [
        rand(0x0010000),
        rand(0x0010000),
        rand(0x0010000),
        rand(0x0010000),
        rand(0x0010000),
        rand(0x1000000),
        rand(0x1000000),
      ]
      "%04x%04x%04x%04x%04x%06x%06x" % values
    end
    
    def queue(q)
      @queues ||= Hash.new { |h,k| h[k] = Queue.new }
      @queues[q]
    end
        
    def delete_queue(q)
      @queues.delete(q)
    end
  end  
end  