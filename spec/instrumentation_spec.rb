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
    end
  end
end
