# frozen_string_literal: true

require "json"
require "time"

# Repository-versioned normalization semantics shared by evidence production
# and verification. Bump VERSION whenever these transformations change.
#
# VERSION 2 (Sprint 118) dropped `goexit_status`. It existed only because the
# oracle used to be `go run`, whose wrapper turns a non-zero program status
# into an "exit status N" line on ITS stderr while exiting 1 itself. The gate
# now builds a native binary with the pinned toolchain and runs it directly, so
# the real status and the real stderr are compared without reinterpretation --
# which is also what stops `os.Exit(3)` and a panic from being conflated.
# VERSION 3 (Sprint 118, Story #3) widened `wallclock` to three further
# renderings of the SAME unavoidable reading, all measured against the pinned
# toolchain on real cross-mode evidence:
#
#   * the monotonic component `m=+0.000044210` that `time.Time.String()` appends
#     — `examples/time` and `examples/epoch`;
#   * the ANSIC layout `Wed Sep  9 04:34:13 2026`, which the pre-existing rule
#     only matched when it ended in `UTC` — `examples/time-formatting-parsing`;
#   * the Kitchen layout `4:34AM` — same row.
#
# Each is a wall-clock reading two separate invocations cannot make agree, which
# is the only thing a normalization is licensed to cancel. None of them widens
# to anything else: `examples/logging` still fails on `logging.go:40` becoming
# `main.go:24`, which is a real source-position defect and not a clock.
# VERSION 4 rejects extra interleaved output and unlicensed worker/job IDs;
# ordering normalization never licenses discarding additional observable events.
module GoByExampleNormalizer
  # VERSION 6 licenses only the pinned closing-channels program's proven
  # partial order; exact event membership and both streams remain checked.
  VERSION = 6
  NAMES = %w[none argv0_path env_listing file_metadata tmp_path ephemeral_port wallclock duration panic_trace random_stream map_order interleave_order closing_channel_order throughput_count pointer_address].freeze
  STDOUT_NAMES = %w[argv0_path env_listing file_metadata tmp_path ephemeral_port duration random_stream map_order interleave_order closing_channel_order throughput_count pointer_address].freeze
  STDERR_NAMES = %w[panic_trace].freeze

  module_function

  # The pinned time example prints one volatile instant and values derived
  # from it. Validate every arithmetic relationship before removing that instant;
  # fixed date fields, comparisons and all output structure remain observable.
  def normalize_time_example(output)
    lines = output.lines.map(&:chomp)
    expected = ["2009", "November", "17", "20", "34", "58", "651387237", "UTC", "Tuesday"]
    raise "time fixed components" unless lines[2, 9] == expected
    parse_ns = ->(text) { (Time.parse(text.sub(/ m=[+-][\d.]+\z/, '')).to_r * 1_000_000_000).to_i }
    now = parse_ns.call(lines[0])
    fixed = (Time.utc(2009, 11, 17, 20, 34, 58).to_r * 1_000_000_000).to_i + 651_387_237
    raise "time fixed instant" unless parse_ns.call(lines[1]) == fixed
    raise "time comparisons" unless lines[11, 3] == [(fixed < now).to_s, (fixed > now).to_s, (fixed == now).to_s]
    difference = now - fixed
    duration = lines[14].match(/\A(?:(\d+)h)?(?:(\d+)m)?(\d+(?:\.\d+)?)s\z/)
    raise "time duration shape" unless duration
    rendered = Integer(duration[1] || '0') * 3_600_000_000_000 + Integer(duration[2] || '0') * 60_000_000_000 + Rational(duration[3]) * 1_000_000_000
    raise "time duration arithmetic" unless rendered == difference && Integer(lines[18]) == difference
    [3_600_000_000_000, 60_000_000_000, 1_000_000_000].each_with_index do |divisor, index|
      actual = Float(lines[15 + index]); expected_value = difference.to_f / divisor
      raise "time duration units" unless actual.finite? && (actual - expected_value).abs <= [expected_value.abs * 1e-14, 1e-9].max
    end
    raise "time addition arithmetic" unless parse_ns.call(lines[19]) == now && parse_ns.call(lines[20]) == 2 * fixed - now
    JSON.generate({"fixed" => lines[1, 10], "comparisons" => lines[11, 3], "duration_units" => "consistent", "additions" => "consistent"})
  end

  def normalize(data, names, stream)
    output = data.dup.force_encoding("UTF-8")
    raise "invalid UTF-8 #{stream}" unless output.valid_encoding?

    names.each do |name|
      next if name == "none" || (stream == :stdout && STDERR_NAMES.include?(name)) || (stream == :stderr && STDOUT_NAMES.include?(name))

      case name
      when "argv0_path"
        lines = output.lines
        raise "argv0_path shape" unless lines[0]&.start_with?("[")
        lines[0] = lines[0].sub(/\A\[[^\] ]+/, "[<argv0>")
        output = lines.join
      when "env_listing"
        lines = output.lines
        separator = lines.index("\n")
        raise "env_listing shape" unless separator && lines[0]&.start_with?("FOO:") && lines[1]&.start_with?("BAR:")
        keys = lines[(separator + 1)..]
        raise "env key shape" unless keys.all? { |line| line.match?(/\A[A-Za-z_][A-Za-z0-9_]*\n?\z/) }
        output = lines[0..separator].join + keys.sort.join
      when "tmp_path"
        output = output.gsub(%r{(?:/[^\s]+/)?sample(?:dir)?\d+}, "<tmp>")
      when "pointer_address"
        output = output.gsub(/0x[0-9a-fA-F]+/, "<ptr>")
      when "wallclock"
        next if output.empty?
        if stream == :stdout && output.lines.size == 21 && output.lines[1].start_with?("2009-11-17 ")
          output = normalize_time_example(output)
          next
        end
        values = output.scan(/\bm=[+-][\d.]+|\b\d{4}[-\/]\d\d[-\/]\d\d(?:T| )[0-9:.+\-Z ]+|\b(?:Mon|Tue|Wed|Thu|Fri|Sat|Sun)\s+\w+\s+\d+\s+\d\d:\d\d:\d\d\s+(?:UTC\s+)?\d{4}\b|\b\d{1,2}:\d\d(?:AM|PM)\b|(?<![\w.])\d{10,19}(?![\w.])/)
        if values.empty?
          raise "wallclock shape" unless output.match?(/It's a (?:weekend|weekday)/) && output.match?(/It's before noon|It's after noon/)
          output = output.gsub(/It's a (?:weekend|weekday)/, "<volatile:day-class>").gsub(/It's (?:before|after) noon/, "<volatile:noon-class>")
        else
          parsed = values.map { |value| value.match?(/\A\d+\z/) ? Integer(value) : (value.start_with?("m=") ? value : Time.parse(value.tr("/", "-"))) rescue value }
          raise "wallclock order" if parsed.grep(Integer).each_cons(2).any? { |a, b| b < a }
          shape = output.dup
          values.each_with_index { |value, index| shape.sub!(value, "<volatile:time:#{index}>") }
          output = JSON.generate({"shape" => shape, "types" => parsed.map { |value| value.class.name }, "ordered" => true})
        end
      when "duration"
        values = output.scan(/\b\d+(?:\.\d+)?(?:ns|µs|us|ms|s)\b/)
        raise "duration shape" if values.empty?
        output = JSON.generate({"text" => output, "values" => values})
      when "panic_trace"
        raise "panic trace shape" unless output.include?("panic:")
        output = output.lines.take_while { |line| !line.start_with?("goroutine ") }.join
      when "random_stream"
        lines = output.lines
        raise "random stream arity" unless lines.size == 5
        ints = lines[0].strip.split(",").map { |value| Integer(value) }
        unit = Float(lines[1])
        floats = lines[2].strip.split(",").map { |value| Float(value) }
        tail = lines[3..].map { |line| line.strip.split(",").map { |value| Integer(value) } }
        raise "random range" unless ints.size == 2 && ints.all? { |value| (0...100).cover?(value) } && (0.0...1.0).cover?(unit) && floats.size == 2 && floats.all? { |value| (5.0...10.0).cover?(value) } && tail.size == 2 && tail[0] == tail[1]
        output = JSON.generate({"shape" => ["int<100,int<100", "float[0,1)", "float[5,10),float[5,10)", "seeded-pair", "same-seeded-pair"], "tail" => tail[0]})
      when "map_order"
        lines = output.lines
        raise "map shape" unless lines.size == 8 && lines[0, 2] == ["sum: 9\n", "index: 1\n"] && lines[6, 2] == ["0 103\n", "1 111\n"]
        pairs = lines[2, 2]
        keys = lines[4, 2]
        raise "map members" unless pairs.sort == ["a -> apple\n", "b -> banana\n"] && keys.sort == ["key: a\n", "key: b\n"]
        output = (lines[0, 2] + pairs.sort + keys.sort + lines[6, 2]).join
      when "closing_channel_order"
        # Each log follows its send/receive, not the other goroutine's log.
        # Capacity 5 exceeds the three jobs: no additional buffer-full edge.
        producer = ["sent job 1\n", "sent job 2\n", "sent job 3\n", "sent all jobs\n"]
        consumer = ["received job 1\n", "received job 2\n", "received job 3\n", "received all jobs\n"]
        final = "received more jobs: false\n"
        expected = producer + consumer + [final]
        lines = output.lines
        raise "closing channel event membership" unless lines.sort == expected.sort
        positions = lines.each_with_index.to_h
        edges = producer.each_cons(2).to_a + consumer.each_cons(2).to_a +
                [[producer[0], consumer[1]], [producer[1], consumer[2]],
                 [producer[2], consumer[3]], [producer[3], final], [consumer[3], final]]
        raise "closing channel causal order" unless edges.all? { |a, b| positions[a] < positions[b] }
        output = expected.join
      when "interleave_order"
        lines = output.lines
        raise "interleave shape" if lines.empty?
        if lines.any? { |line| line.start_with?("direct") }
          raise "direct causal order" unless lines[0, 3] == ["direct : 0\n", "direct : 1\n", "direct : 2\n"] && lines[-1] == "done\n"
          middle = lines[3...-1]
          raise "unexpected interleave output" unless middle.size == 4 && middle.all? { |line| line == "going\n" || line.match?(/\Agoroutine : [012]\n\z/) }
          goroutine = middle.select { |line| line.start_with?("goroutine") }
          raise "goroutine subsequence" unless goroutine == ["goroutine : 0\n", "goroutine : 1\n", "goroutine : 2\n"] && middle.count("going\n") == 1
          output = JSON.generate({"prefix" => lines[0, 3], "chains" => [goroutine, ["going\n"]], "suffix" => [lines[-1]]})
        elsif lines.any? { |line| line.start_with?("Worker") }
          events = lines.map { |line| line.match(/\AWorker (\d+) (starting|done)\n\z/)&.captures }
          raise "worker event shape" if events.any?(&:nil?) || events.size != 10 || events.any? { |id, _| !(1..5).cover?(id.to_i) }
          (1..5).each do |id|
            positions = events.each_index.select { |index| events[index][0].to_i == id }
            raise "worker causal order" unless positions.size == 2 && events[positions[0]][1] == "starting" && events[positions[1]][1] == "done"
          end
          output = JSON.generate({"workers" => (1..5).map { |id| [id, "starting", "done"] }})
        else
          events = lines.map { |line| line.match(/\Aworker (\d+) (started |finished) job (\d+)\n\z/)&.captures }
          raise "pool event shape" if events.any?(&:nil?) || events.size != 10 || events.any? { |worker, _, job| !(1..3).cover?(worker.to_i) || !(1..5).cover?(job.to_i) }
          (1..5).each do |job|
            positions = events.each_index.select { |index| events[index][2].to_i == job }
            raise "pool causal order" unless positions.size == 2 && events[positions[0]][1].start_with?("started") && events[positions[1]][1] == "finished" && events[positions[0]][0] == events[positions[1]][0]
          end
          output = JSON.generate({"jobs" => (1..5).to_a, "constraint" => "same-worker start-before-finish"})
        end
      when "throughput_count"
        lines = output.lines
        parsed = lines.map { |line| line.match(/\A(readOps|writeOps): (\d+)\n?\z/)&.captures }
        raise "throughput shape" unless lines.size == 2 && parsed.none?(&:nil?) && parsed.map(&:first) == %w[readOps writeOps] && parsed.all? { |_, value| Integer(value).positive? }
        output = JSON.generate({"readOps" => "positive integer", "writeOps" => "positive integer"})
      when "file_metadata"
        output = output.lines.map { |line| line.match?(/\A[-dl][rwx-]{9}[@+]?\s+/) ? line.sub(/\A([-dl][rwx-]{9})[@+]?\s+\d+\s+\S+\s+\S+\s+\S+\s+\S+\s+\d+\s+\d\d:\d\d/, '\\1 <metadata>') : line }.join
      when "ephemeral_port"
        output = output.gsub(/(?<=:)\d{2,5}\b/, "<port>")
      else
        raise "normalizer has no implementation: #{name}"
      end
    end
    output
  end
end
