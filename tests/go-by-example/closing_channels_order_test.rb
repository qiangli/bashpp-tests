# frozen_string_literal: true
# Sprint: #118; Story: #3; Story-ID: fa07603b71dc
require 'minitest/autorun'
require 'set'
require 'digest'
require 'open3'
require 'tmpdir'
require_relative '../../tools/go-by-example/normalizer'

class ClosingChannelsOrderTest < Minitest::Test
  PRODUCER = (1..3).map { |n| "sent job #{n}\n" } + ["sent all jobs\n"]
  CONSUMER = (1..3).map { |n| "received job #{n}\n" } + ["received all jobs\n"]
  FINAL = "received more jobs: false\n"
  EVENTS = PRODUCER + CONSUMER + [FINAL]

  def normalize(text)
    GoByExampleNormalizer.normalize(text, ['closing_channel_order'], :stdout)
  end

  # Independent executable small-step model of the unchanged source. It models
  # hidden sends, FIFO receives, capacity, close and the unbuffered done handshake,
  # then projects only print operations. No comparator edges are used here.
  def operational_traces
    producer = (1..3).flat_map { |n| [[:send, n], [:print, PRODUCER[n - 1]]] } +
               [[:close], [:print, PRODUCER[3]], [:done_receive], [:closed_receive], [:print, FINAL]]
    consumer = (1..3).flat_map { |n| [[:receive, n], [:print, CONSUMER[n - 1]]] } +
               [[:closed_receive], [:print, CONSUMER[3]], [:done_send]]
    memo = {}
    visit = nil
    visit = lambda do |pi, ci, queue, closed|
      key = [pi, ci, queue, closed]
      return memo[key] if memo.key?(key)
      return Set[[]] if pi == producer.size && ci == consumer.size
      traces = Set.new
      if producer[pi]&.first == :done_receive && consumer[ci]&.first == :done_send
        traces.merge(visit.call(pi + 1, ci + 1, queue, closed))
      end
      [producer[pi], consumer[ci]].each_with_index do |op, actor|
        next unless op
        next_queue = queue
        next_closed = closed
        event = nil
        case op.first
        when :send
          next if closed || queue.size == 5
          next_queue = queue + [op[1]]
        when :receive
          next unless queue.first == op[1]
          next_queue = queue.drop(1)
        when :close
          next if closed
          next_closed = true
        when :closed_receive
          next unless closed && queue.empty?
        when :print
          event = op[1]
        else
          next # done operations only advance together above.
        end
        tails = visit.call(pi + (actor == 0 ? 1 : 0), ci + (actor == 1 ? 1 : 0), next_queue, next_closed)
        tails.each { |tail| traces.add(event ? [event] + tail : tail) }
      end
      memo[key] = traces
    end
    visit.call(0, 0, [], false)
  end

  def test_all_event_permutations_equal_independent_operational_model
    expected = operational_traces.map(&:join).to_set
    accepted = Set.new
    EVENTS.permutation.each do |events|
      text = events.join
      begin
        normalize(text)
        accepted.add(text)
      rescue RuntimeError
        # Rejection is expected for traces absent from the source state machine.
      end
    end
    assert_operator expected.size, :>, 1
    assert_equal expected, accepted
    assert_equal 1, accepted.map { |text| normalize(text) }.uniq.size
  end

  def test_membership_values_streams_and_newlines_remain_observable
    good = EVENTS.join
    mutations = EVENTS.each_index.map { |i| (EVENTS[0...i] + EVENTS[(i + 1)..]).join } +
                EVENTS.map { |event| good + event } +
                [good + "unexpected\n", good.sub('job 2', 'job 9'), good.sub('false', 'true'),
                 good.chomp, good.gsub("\n", "\r\n"), good.sub("sent job 2\n", "sent job 1\n")]
    mutations.each { |text| assert_raises(RuntimeError) { normalize(text) } }
    assert_equal 'observable error', GoByExampleNormalizer.normalize('observable error', ['closing_channel_order'], :stderr)
    refute_equal good, EVENTS.reverse.join
    assert_equal good, GoByExampleNormalizer.normalize(good, ['none'], :stdout)
    assert_equal EVENTS.reverse.join, GoByExampleNormalizer.normalize(EVENTS.reverse.join, ['none'], :stdout)
  end

  def test_schema_rule_cannot_be_reused_for_other_source_or_modified_bytes
    root = File.expand_path('../..', __dir__)
    Dir.mktmpdir('closing-channel-binding-') do |dir|
      classification = File.read(File.join(root, 'docs/go-by-example/classification.tsv'))
      classification = classification.sub("examples/atomic-counters/atomic-counters.go\tprogram\tconcurrency\tnone\t",
                                          "examples/atomic-counters/atomic-counters.go\tprogram\tconcurrency\tclosing_channel_order\t")
      path = File.join(dir, 'classification.tsv')
      File.write(path, classification)
      out, status = Open3.capture2e({'GBE_CLASSIFICATION' => path}, 'bash', File.join(root, 'tools/go-by-example/validate.sh'))
      refute status.success?
      assert_includes out, 'bound exclusively to the reviewed closing-channels row'
      inventory = File.read(File.join(root, 'docs/go-by-example/inventory.tsv'))
      inventory = inventory.sub('b2ddb4aa5bce6a532fc9bc29e67800e1a31f8da7fb7131f4ee8bde7eecfbe15c', '0' * 64)
      path = File.join(dir, 'inventory.tsv')
      File.write(path, inventory)
      out, status = Open3.capture2e({'GBE_INVENTORY' => path}, 'bash', File.join(root, 'tools/go-by-example/validate.sh'))
      refute status.success?
      assert_includes out, 'source digest is not the reviewed program'
    end
  end

  def test_retained_real_native_orders_and_exact_original_source
    root = File.expand_path('../..', __dir__)
    source = File.join(root, 'examples/closing-channels/closing-channels.go')
    assert_equal 'b2ddb4aa5bce6a532fc9bc29e67800e1a31f8da7fb7131f4ee8bde7eecfbe15c', Digest::SHA256.file(source).hexdigest
    dir = File.join(__dir__, 'fixtures/closing-channels')
    provenance = JSON.parse(File.read(File.join(dir, 'provenance.json')))
    assert_equal 192, provenance.fetch('native_runs')
    observed = provenance.fetch('files').map do |file|
      path = File.join(dir, file.fetch('file'))
      assert_equal file.fetch('sha256'), Digest::SHA256.file(path).hexdigest
      assert_equal 0, file.fetch('capture').fetch('exit')
      assert_equal 0, file.fetch('capture').fetch('stderr').fetch('bytes')
      normalize(File.binread(path))
    end
    assert_equal 6, observed.size
    assert_equal 1, observed.uniq.size
  end
end
