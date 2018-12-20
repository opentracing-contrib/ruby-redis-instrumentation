require "redis/instrumentation/version"
require "opentracing"
require "redis"

# this is a class instead of module to match how Redis does it
# otherwise this name will collide
class Redis
  module Instrumentation
    class << self

      attr_accessor :tracer

      def instrument(tracer: OpenTracing.global_tracer)
        begin
          require 'redis'
        rescue LoadError => e
          return
        end

        @tracer = tracer

        patch_client if !@patched_client
        @patched_client = true
      end

      def patch_client
        ::Redis::Client.class_eval do
          alias_method :call_original, :call
          alias_method :call_pipelined_original, :call_pipelined

          def call(command, trace: true)
            tags = {
              'span.kind' => 'client',
              'component' => 'redis-rb',
              'db.type' => 'redis',
              'db.statement' => command.join(' '),
            }

            # command[0] is usually the actual command name
            scope = ::Redis::Instrumentation.tracer.start_active_span("redis.#{command[0]}", tags: tags)

            call_original(command)
          ensure
            scope.close if scope
          end

          def call_pipelined(commands)
            statement = commands.empty? ? "" : commands.map{ |arr| arr.join(' ') }.join(', ')
            tags = {
              'span.kind' => 'client',
              'component' => 'redis-rb',
              'db.type' => 'redis',
              'db.statement' => statement,
            }

            scope = ::Redis::Instrumentation.tracer.start_active_span("redis.pipelined", tags: tags)

            call_pipelined_original(commands)
          ensure
            scope.close if scope
          end
        end
      end # patch_client
    end
  end
end
