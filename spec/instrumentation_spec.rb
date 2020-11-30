require 'spec_helper'

RSpec.describe Redis::Instrumentation do
  describe "Class Methods" do
    it { should respond_to :instrument }
    it { should respond_to :patch_client }
  end

  let (:tracer) { OpenTracingTestTracer.build }
  let (:redis) { ::Redis.new(host: 'localhost', port: 6379) }

  before do
    allow_any_instance_of(::Redis::Client).to receive(:process).and_return(["test"])

    Redis::Instrumentation.instrument(tracer: tracer)
  end

  describe :instrument do
    let (:client) { redis._client }

    before { tracer.spans.clear }

    it 'patches methods' do
      expect(client).to respond_to(:call_original)
      expect(client).to respond_to(:call_pipeline_original)
    end

    describe 'regular commands' do
      it 'calls the original call method' do
        expect(client).to receive(:call_original)
        redis.get("foo")
      end

      it 'adds spans' do
        redis.set("foo", "bar")

        expect(tracer.spans.count).to be 1

        span_tags = tracer.spans.last.tags
        expected_tags = {
          'span.kind' => 'client',
          'component' => 'ruby-redis',
          'db.type' => 'redis',
          'db.instance' => 0,
          'peer.address' => 'redis://localhost:6379',
          'db.statement' => 'set foo bar'
        }
        expect(span_tags).to eq expected_tags
      end

      it 'yields to blocks' do
        expect { |b| client.call([:set, "foo", "bar"], &b) }.to yield_control
      end

      it "logs errors as semantic key value pairs" do
        expected_error = Redis::CannotConnectError.new("unable to connect")
        allow_any_instance_of(::Redis::Client).to receive(:process).and_raise(expected_error)

        expect { redis.set("foo", "bar") }.to raise_error(expected_error)

        expect(tracer.spans.count).to be 1


        span_tags = tracer.spans.last.tags
        expected_tags = {
          'span.kind' => 'client',
          'component' => 'ruby-redis',
          'db.type' => 'redis',
          'db.instance' => 0,
          'peer.address' => 'redis://localhost:6379',
          'db.statement' => 'set foo bar',
          'error' => true,
          'sfx.error.kind' => expected_error.class.to_s,
          'sfx.error.message' => expected_error.to_s,
          'sfx.error.stack' => expected_error.backtrace.join('\n')
        }
        expect(span_tags).to eq expected_tags
      end
    end

    describe 'pipelined commands' do
      it 'calls the original pipeline method' do
        expect(client).to receive(:call_pipeline_original)

        redis.multi do
          redis.set 'foo', 'bar'
          redis.incr 'baz'
        end
      end

      it 'adds a span' do
        redis.multi do
          redis.set 'foo', 'bar'
          redis.incr 'baz'
        end

        expect(tracer.spans.count).to be 1

        span_tags = tracer.spans.last.tags
        expected_tags = {
          'span.kind' => 'client',
          'component' => 'ruby-redis',
          'db.type' => 'redis',
          'db.instance' => 0,
          'peer.address' => 'redis://localhost:6379',
          'db.statement' => 'multi, set foo bar, incr baz, exec'
        }
        expect(span_tags).to eq expected_tags
      end

      it "logs errors as semantic key value pairs" do
        expected_error = Redis::CannotConnectError.new("unable to connect")
        allow_any_instance_of(::Redis::Client).to receive(:process).and_raise(expected_error)

        expect {
          redis.multi {
            redis.set 'foo', 'bar'
            redis.incr 'baz'
          }
        }.to raise_error(expected_error)

        expect(tracer.spans.count).to be 1

        span_tags = tracer.spans.last.tags
        expected_tags = {
          'span.kind' => 'client',
          'component' => 'ruby-redis',
          'db.type' => 'redis',
          'db.instance' => 0,
          'peer.address' => 'redis://localhost:6379',
          'db.statement' => 'multi, set foo bar, incr baz, exec',
          'error' => true
        }
        expect(span_tags).to eq expected_tags

        span_logs = tracer.spans.last.logs.last
        expect(span_logs).to include("error.kind": "Redis::CannotConnectError", "error.object": expected_error, message: expected_error.message)
      end
    end

    describe 'Truncated db statements' do
      before do
        Redis::Instrumentation.instrument(tracer: tracer, db_statement_length: 5)
      end

      it 'truncates regular statements' do
        redis.set("foo", "a" * 1024)
        expect(tracer.spans.count).to be 1

        span_tags = tracer.spans.last.tags
        expect(span_tags['db.statement']).to eq 'set f'
      end

      it 'truncates pipeline statement' do
        redis.multi do
          redis.set 'foo', 'bar'
          redis.incr 'baz'
        end
        expect(tracer.spans.count).to be 1

        span_tags = tracer.spans.last.tags
        expect(span_tags['db.statement']).to eq 'multi'
      end
    end
  end
end
