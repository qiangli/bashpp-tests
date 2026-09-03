# frozen_string_literal: true

require "json"
require "time"

# Repository-versioned normalization semantics shared by evidence production
# and verification. Bump VERSION whenever these transformations change.
module GoByExampleNormalizer
  VERSION = 1
  NAMES = %w[none argv0_path env_listing file_metadata tmp_path ephemeral_port wallclock duration goexit_status panic_trace random_stream map_order interleave_order throughput_count pointer_address].freeze
  STDOUT_NAMES = %w[argv0_path env_listing file_metadata tmp_path ephemeral_port wallclock duration random_stream map_order interleave_order throughput_count pointer_address].freeze
  STDERR_NAMES = %w[goexit_status panic_trace].freeze

  module_function

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
        values = output.scan(/\b\d{4}[-\/]\d\d[-\/]\d\d(?:T| )[0-9:.+\-Z ]+|\b(?:Mon|Tue|Wed|Thu|Fri|Sat|Sun)\s+\w+\s+\d+\s+\d\d:\d\d:\d\d\s+UTC\s+\d{4}\b|(?<![\w.])\d{10,19}(?![\w.])/)
        if values.empty?
          raise "wallclock shape" unless output.match?(/It's a (?:weekend|weekday)/) && output.match?(/It's before noon|It's after noon/)
          output = output.gsub(/It's a (?:weekend|weekday)/, "<volatile:day-class>").gsub(/It's (?:before|after) noon/, "<volatile:noon-class>")
        else
          parsed = values.map { |value| value.match?(/\A\d+\z/) ? Integer(value) : Time.parse(value.tr("/", "-")) rescue value }
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
      when "goexit_status"
        output = output.gsub(/^exit status (\d+)$/) { "exit status:#{$1}" }
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
      when "interleave_order"
        lines = output.lines
        raise "interleave shape" if lines.empty?
        if lines.any? { |line| line.start_with?("direct") }
          raise "direct causal order" unless lines[0, 3] == ["direct : 0\n", "direct : 1\n", "direct : 2\n"] && lines[-1] == "done\n"
          middle = lines[3...-1]
          goroutine = middle.select { |line| line.start_with?("goroutine") }
          raise "goroutine subsequence" unless goroutine == ["goroutine : 0\n", "goroutine : 1\n", "goroutine : 2\n"] && middle.count("going\n") == 1
          output = JSON.generate({"prefix" => lines[0, 3], "chains" => [goroutine, ["going\n"]], "suffix" => [lines[-1]]})
        elsif lines.any? { |line| line.start_with?("Worker") }
          events = lines.map { |line| line.match(/\AWorker (\d+) (starting|done)\n\z/)&.captures }
          raise "worker event shape" if events.any?(&:nil?)
          (1..5).each do |id|
            positions = events.each_index.select { |index| events[index][0].to_i == id }
            raise "worker causal order" unless positions.size == 2 && events[positions[0]][1] == "starting" && events[positions[1]][1] == "done"
          end
          output = JSON.generate({"workers" => (1..5).map { |id| [id, "starting", "done"] }})
        else
          events = lines.map { |line| line.match(/\Aworker (\d+) (started |finished) job (\d+)\n\z/)&.captures }
          raise "pool event shape" if events.any?(&:nil?)
          (1..5).each do |job|
            positions = events.each_index.select { |index| events[index][2].to_i == job }
            raise "pool causal order" unless positions.size == 2 && events[positions[0]][1].start_with?("started") && events[positions[1]][1] == "finished" && events[positions[0]][0] == events[positions[1]][0]
          end
          output = JSON.generate({"jobs" => (1..5).to_a, "constraint" => "same-worker start-before-finish"})
        end
      when "throughput_count"
        values = output.scan(/^(readOps|writeOps): (\d+)$/).to_h.transform_values(&:to_i)
        raise "throughput shape" unless values.keys.sort == %w[readOps writeOps] && values.values.all?(&:positive?)
        output = JSON.generate(values)
      when "file_metadata"
        output = output.lines.map { |line| line.match?(/\A[-dl][rwx-]{9}\s+/) ? line.sub(/\A([-dl][rwx-]{9})\s+\d+\s+\S+\s+\S+\s+\S+\s+\S+\s+\d+\s+\d\d:\d\d/, '\\1 <metadata>') : line }.join
      when "ephemeral_port"
        output = output.gsub(/(?<=:)\d{2,5}\b/, "<port>")
      else
        raise "normalizer has no implementation: #{name}"
      end
    end
    output
  end
end
