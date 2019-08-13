require "redis/instrumentation/version"
require "opentracing"
require "redis"

# this is a class instead of module to match how Redis does it
# otherwise this name will collide
class Redis
  module Instrumentation
    COMMON_TAGS = {
      'span.kind' => 'client',
      'component' => 'ruby-redis',
      'db.type' => 'redis',
    }.freeze

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
          alias_method :call_pipeline_original, :call_pipeline

          def call(command, trace: true, &block)
            tags = ::Redis::Instrumentation::COMMON_TAGS.dup
            tags['db.statement'] = command.join(' ')
            tags['db.instance'] = db
            tags['peer.address'] = "redis://#{host}:#{port}"

            # command[0] is usually the actual command name
            scope = ::Redis::Instrumentation.tracer.start_active_span("redis.#{command[0]}", tags: tags)

            call_original(command, &block)
          rescue => e
            if scope
              scope.span.set_tag("error", true)
              scope.span.log_kv(key: "message", value: e.message)
            end
            raise e
          ensure
            scope.close if scope
          end

          def call_pipeline(pipeline)
            commands = pipeline.commands
            tags = ::Redis::Instrumentation::COMMON_TAGS.dup
            tags['db.statement'] = commands.empty? ? "" : commands.map{ |arr| arr.join(' ') }.join(', ')
            tags['db.instance'] = db
            tags['peer.address'] = "redis://#{host}:#{port}"

            scope = ::Redis::Instrumentation.tracer.start_active_span("redis.pipelined", tags: tags)

            call_pipeline_original(pipeline)
          rescue => e
            if scope
              scope.span.set_tag("error", true)
              scope.span.log_kv(key: "message", value: e.message)
            end
            raise e
          ensure
            scope.close if scope
          end
        end
      end # patch_client
    end
  end
end
