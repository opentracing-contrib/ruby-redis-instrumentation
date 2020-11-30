require "redis/instrumentation/version"
require "opentracing"

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
      attr_accessor :db_statement_length

      def instrument(tracer: OpenTracing.global_tracer,
                     db_statement_length: nil)
        begin
          require 'redis'
        rescue LoadError => e
          return
        end

        @tracer = tracer
        @db_statement_length = db_statement_length

        patch_client if !@patched_client
        @patched_client = true
      end

      def patch_client
        ::Redis::Client.class_eval do
          alias_method :call_original, :call
          alias_method :call_pipeline_original, :call_pipeline

          def call(command, trace: true, &block)
            tags = ::Redis::Instrumentation::COMMON_TAGS.dup
            statement = command.join(' ')
            statement = statement.to_s[0, ::Redis::Instrumentation::db_statement_length] if ::Redis::Instrumentation::db_statement_length
            tags['db.statement'] = statement
            tags['db.instance'] = db
            tags['peer.address'] = "redis://#{host}:#{port}"

            # command[0] is usually the actual command name
            scope = ::Redis::Instrumentation.tracer.start_active_span("redis.#{command[0]}", tags: tags)

            call_original(command, &block)
          rescue => e
            if scope
              scope.span.record_exception(e)
            end
            raise e
          ensure
            scope.close if scope
          end

          def call_pipeline(pipeline)
            commands = pipeline.commands
            tags = ::Redis::Instrumentation::COMMON_TAGS.dup
            statement = commands.empty? ? "" : commands.map{ |arr| arr.join(' ') }.join(', ')
            statement = statement.to_s[0, ::Redis::Instrumentation::db_statement_length] if ::Redis::Instrumentation::db_statement_length
            tags['db.statement'] = statement
            tags['db.instance'] = db
            tags['peer.address'] = "redis://#{host}:#{port}"

            scope = ::Redis::Instrumentation.tracer.start_active_span("redis.pipelined", tags: tags)

            call_pipeline_original(pipeline)
          rescue => e
            if scope
              scope.span.set_tag("error", true)
              scope.span.log_kv("error.kind": e.class.name, message: e.message, "error.object": e)
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
