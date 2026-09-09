#!/usr/bin/env ruby
# frozen_string_literal: true
#
# Negative-first selftests for the reviewed semantic comparators.
#
# Sprint 118 / Story #4 / Story-ID 759341a95870.
#
# A semantic comparator is only worth anything if it REJECTS. Every comparator
# in tools/tour/semantics.rb is driven here with:
#
#   * a real-shaped accepted case (so the suite proves the comparators can
#     pass, and is not merely always red);
#   * wrong VALUES (a draw outside the declared support, a wrong rendered
#     octet, a wrong body, a wrong greeting);
#   * wrong COUNTS (too few or too many events, duplicated lines, a
#     multiplicity outside the range the native repeats actually showed);
#   * wrong ORDER (a causal pair inverted, a terminal event that is not
#     terminal, elapsed time going backwards);
#   * wrong STATUS (a nonzero exit, unexpected stderr) — never adjudicated
#     semantically, always compared exactly;
#   * wrong TIMING (an event before its earliest possible instant, a timestamp
#     outside the recorded run window, a missing monotonic reading);
#   * a degenerate ORACLE (too few repeats, or no observed variation where the
#     volatile element must vary), which must fail rather than license;
#   * ANOTHER ROW'S output, which every comparator must reject.
#
# The table bindings are tested too: a comparator cannot be bound to a row
# whose pinned source digest differs.

require 'json'
require 'tmpdir'
require_relative 'semantics'

ROOT = File.expand_path('../..', __dir__)
PASSED = []
FAILED = []

def check(name)
  result = yield
  result == true ? PASSED << name : FAILED << "#{name}: #{result}"
rescue StandardError => e
  FAILED << "#{name}: raised #{e.class}: #{e.message}"
end

def expect(condition, message)
  condition ? true : message
end

TABLE = TourSemantics.load_table(File.join(ROOT, 'docs/tour/semantics.tsv'))

# A fixed window: Tuesday 2026-09-08, 21:19 local. Tuesday is neither Saturday
# nor the day before nor two days before, and 21:19 is after 17:00, so the
# clock-derived expectations are "Too far away." and "Good evening.".
WINDOW_FROM = Time.new(2026, 9, 8, 21, 19, 0)
WINDOW = { 'from' => WINDOW_FROM.to_f, 'to' => WINDOW_FROM.to_f + 12.0, 'utc_offset' => WINDOW_FROM.utc_offset }.freeze

def go_stamp(offset_seconds = 1.0, monotonic: '0.000073835')
  time = Time.at(WINDOW['from'] + offset_seconds)
  stamp = time.strftime('%Y-%m-%d %H:%M:%S.%6N %z %Z')
  monotonic ? "#{stamp} m=+#{monotonic}" : stamp
end

def observation(stdout, exit_status: 0, stderr: '')
  { 'exit' => exit_status, 'stdout' => stdout, 'stderr' => stderr }
end

# Runs one comparator and returns its findings.
def findings(path, candidate, oracle, window: WINDOW)
  TourSemantics.compare(TABLE.fetch(path), candidate: candidate, oracle: oracle, window: window)['findings']
end

# Asserts the comparator ACCEPTS.
def accepts(name, path, candidate, oracle, window: WINDOW)
  check(name) do
    got = findings(path, candidate, oracle, window: window)
    expect(got.empty?, "expected acceptance, got #{got.inspect}")
  end
end

# Asserts the comparator REJECTS with a finding containing `token`.
def rejects(name, path, candidate, oracle, token, window: WINDOW)
  check(name) do
    got = findings(path, candidate, oracle, window: window)
    return "expected rejection (#{token}), got acceptance" if got.empty?
    expect(got.any? { |f| f.include?(token) }, "expected a finding containing #{token.inspect}, got #{got.inspect}")
  end
end

# ============================================================ packages ======

PACKAGES = '_content/tour/basics/packages.go'
def packages_line(value)
  observation("My favorite number is #{value}\n")
end
PACKAGES_ORACLE = [2, 7, 0, 9, 4, 7, 1].map { |v| packages_line(v) }

accepts('rand_intn_line: a draw inside the declared support', PACKAGES, packages_line(3), PACKAGES_ORACLE)
accepts('rand_intn_line: a draw the oracle never produced is still in support', PACKAGES, packages_line(5), PACKAGES_ORACLE)
rejects('rand_intn_line: rejects a draw OUTSIDE rand.Intn(10) support', PACKAGES, packages_line(10), PACKAGES_ORACLE, 'value_outside_support')
rejects('rand_intn_line: rejects a negative draw', PACKAGES, packages_line(-1), PACKAGES_ORACLE, 'shape')
rejects('rand_intn_line: rejects a non-numeric value', PACKAGES, packages_line('seven'), PACKAGES_ORACLE, 'shape')
rejects('rand_intn_line: rejects altered surrounding text', PACKAGES,
        observation("My lucky number is 3\n"), PACKAGES_ORACLE, 'shape')
rejects('rand_intn_line: rejects an extra line', PACKAGES,
        observation("My favorite number is 3\nextra\n"), PACKAGES_ORACLE, 'line_count')
rejects('rand_intn_line: rejects empty output', PACKAGES, observation(''), PACKAGES_ORACLE, 'line_count')
rejects('rand_intn_line: STATUS is never semantic — a nonzero exit fails', PACKAGES,
        packages_line(3).merge('exit' => 1), PACKAGES_ORACLE, 'status:exit_mismatch')
rejects('rand_intn_line: STDERR is never semantic — unexpected stderr fails', PACKAGES,
        packages_line(3).merge('stderr' => "warning\n"), PACKAGES_ORACLE, 'stderr:mismatch')
rejects('rand_intn_line: a too-thin oracle cannot establish anything', PACKAGES,
        packages_line(3), PACKAGES_ORACLE.first(3), 'oracle:insufficient_runs')
rejects('rand_intn_line: an oracle with NO variation means the comparator is not needed', PACKAGES,
        packages_line(3), Array.new(7) { packages_line(3) }, 'oracle:no_variation_observed')
rejects('rand_intn_line: an oracle observation outside support fails the comparator itself', PACKAGES,
        packages_line(3), PACKAGES_ORACLE[0..5] + [packages_line(11)], 'oracle:invariant_violation')

# ========================================================== goroutines ======

GOROUTINES = '_content/tour/concurrency/goroutines.go'
def say(sequence)
  observation(sequence.map { |s| "#{s}\n" }.join)
end
GOROUTINES_ORACLE = [
  say(%w[hello world world hello world hello hello world hello]),
  say(%w[world hello world hello world hello world hello hello world]),
  say(%w[hello world hello world hello world hello world hello]),
  say(%w[world hello hello world world hello world hello hello world]),
  say(%w[hello hello world world hello world hello world hello]),
  say(%w[hello world world hello hello world hello world hello world]),
  say(%w[world world hello hello hello world world hello hello])
].freeze

accepts('say_interleaving: any interleaving with the right multiplicities', GOROUTINES,
        say(%w[world hello world hello hello world hello world hello]), GOROUTINES_ORACLE)
rejects('say_interleaving: rejects too FEW main lines', GOROUTINES,
        say(%w[hello world hello world hello world hello world]), GOROUTINES_ORACLE, 'main_multiplicity')
rejects('say_interleaving: rejects too MANY main lines', GOROUTINES,
        say(%w[hello] * 6 + %w[world] * 4), GOROUTINES_ORACLE, 'main_multiplicity')
rejects('say_interleaving: rejects a goroutine count above its own bound', GOROUTINES,
        say(%w[hello] * 5 + %w[world] * 6), GOROUTINES_ORACLE, 'goroutine_multiplicity_outside_bound')
rejects('say_interleaving: rejects a goroutine count outside the NATIVE observed range', GOROUTINES,
        say(%w[hello] * 5), GOROUTINES_ORACLE, 'outside_native_range')
rejects('say_interleaving: rejects an unknown line', GOROUTINES,
        say(%w[hello world hola hello world hello world hello world hello]), GOROUTINES_ORACLE, 'unknown_line')
rejects('say_interleaving: rejects a wrong exit status', GOROUTINES,
        say(%w[hello world hello world hello world hello world hello]).merge('exit' => 2),
        GOROUTINES_ORACLE, 'status:exit_mismatch')

# ==================================================== default-selection =====

SELECT = '_content/tour/concurrency/default-selection.go'
def tick_line(ms, kind)
  body = { tick: 'tick.', boom: 'BOOM!', default: '    .' }.fetch(kind)
  format("[%6s] %s\n", "#{ms}ms", body)
end
def tick_run(events)
  observation(events.map { |ms, kind| tick_line(ms, kind) }.join)
end
SELECT_GOOD = [[0, :default], [51, :default], [101, :tick], [101, :default], [153, :default],
               [205, :tick], [205, :default], [257, :default], [309, :tick], [309, :default],
               [361, :default], [413, :tick], [413, :default], [465, :default], [517, :tick],
               [517, :boom]].freeze
SELECT_ORACLE = (0...7).map { |i| tick_run(SELECT_GOOD.map { |ms, kind| [ms + i, kind] }) }.freeze

accepts('tick_boom_sequence: a real tick/default/BOOM sequence', SELECT, tick_run(SELECT_GOOD), SELECT_ORACLE)
rejects('tick_boom_sequence: rejects BOOM that is not terminal (causal order)', SELECT,
        tick_run(SELECT_GOOD[0..13] + [[517, :boom], [520, :tick]]), SELECT_ORACLE, 'boom_not_final')
rejects('tick_boom_sequence: rejects two BOOMs (event multiplicity)', SELECT,
        tick_run(SELECT_GOOD + [[518, :boom]]), SELECT_ORACLE, 'boom_multiplicity')
rejects('tick_boom_sequence: rejects a BOOM before its 500ms timer (timing condition)', SELECT,
        tick_run([[0, :default], [101, :tick], [205, :tick], [309, :tick], [413, :tick], [430, :boom]]),
        SELECT_ORACLE, 'boom_early')
rejects('tick_boom_sequence: rejects elapsed time going backwards', SELECT,
        tick_run([[0, :default], [101, :tick], [90, :default], [205, :tick], [309, :tick],
                  [413, :tick], [517, :tick], [517, :boom]]),
        SELECT_ORACLE, 'elapsed_not_monotonic')
rejects('tick_boom_sequence: rejects a first tick before 100ms (timing condition)', SELECT,
        tick_run([[0, :default], [40, :tick], [205, :tick], [309, :tick], [413, :tick], [517, :tick], [517, :boom]]),
        SELECT_ORACLE, 'tick_early')
rejects('tick_boom_sequence: rejects a run with no default selection at all', SELECT,
        tick_run([[101, :tick], [205, :tick], [309, :tick], [413, :tick], [517, :tick], [517, :boom]]),
        SELECT_ORACLE, 'no_default_selection')
rejects('tick_boom_sequence: rejects a tick count outside the NATIVE observed range', SELECT,
        tick_run([[0, :default], [101, :tick], [205, :tick], [517, :boom]]), SELECT_ORACLE, 'tick_count')
rejects('tick_boom_sequence: rejects an unparseable line', SELECT,
        observation(tick_run(SELECT_GOOD)['stdout'] + "surprise\n"), SELECT_ORACLE, 'unparsed_line')

# ============================================================ weekday =======

WEEKDAY = '_content/tour/flowcontrol/switch-evaluation-order.go'
def weekday(answer)
  observation("When's Saturday?\n#{answer}\n")
end
WEEKDAY_ORACLE = Array.new(7) { weekday('Too far away.') }

accepts('weekday_switch: the answer the recorded run clock implies', WEEKDAY, weekday('Too far away.'), WEEKDAY_ORACLE)
rejects('weekday_switch: rejects a value-set member that disagrees with the run clock', WEEKDAY,
        weekday('Today.'), WEEKDAY_ORACLE, 'answer_disagrees')
rejects('weekday_switch: rejects a value outside the closed set', WEEKDAY,
        weekday('Someday.'), WEEKDAY_ORACLE, 'answer_outside_value_set')
rejects('weekday_switch: rejects an altered prompt line', WEEKDAY,
        observation("When is Saturday?\nToo far away.\n"), WEEKDAY_ORACLE, 'prompt')
rejects('weekday_switch: rejects a missing line', WEEKDAY,
        observation("Too far away.\n"), WEEKDAY_ORACLE, 'line_count')
check('weekday_switch: a Saturday window implies "Today."') do
  saturday = Time.new(2026, 9, 12, 10, 0, 0)
  window = { 'from' => saturday.to_f, 'to' => saturday.to_f + 5, 'utc_offset' => saturday.utc_offset }
  ok = findings(WEEKDAY, weekday('Today.'), Array.new(7) { weekday('Today.') }, window: window)
  no = findings(WEEKDAY, weekday('Too far away.'), Array.new(7) { weekday('Too far away.') }, window: window)
  expect(ok.empty? && no.any? { |f| f.include?('answer_disagrees_with_run_clock') }, "#{ok.inspect} / #{no.inspect}")
end

# ============================================================ greeting ======

GREETING = '_content/tour/flowcontrol/switch-with-no-condition.go'
def greeting(text)
  observation("#{text}\n")
end
GREETING_ORACLE = Array.new(7) { greeting('Good evening.') }

accepts('hour_greeting: the greeting the recorded run clock implies', GREETING, greeting('Good evening.'), GREETING_ORACLE)
rejects('hour_greeting: rejects a value-set member that disagrees with the run clock', GREETING,
        greeting('Good morning!'), GREETING_ORACLE, 'greeting_disagrees')
rejects('hour_greeting: rejects a value outside the closed set', GREETING,
        greeting('Hi.'), GREETING_ORACLE, 'greeting_outside_value_set')
check('hour_greeting: a morning window implies "Good morning!"') do
  morning = Time.new(2026, 9, 8, 8, 30, 0)
  window = { 'from' => morning.to_f, 'to' => morning.to_f + 5, 'utc_offset' => morning.utc_offset }
  ok = findings(GREETING, greeting('Good morning!'), Array.new(7) { greeting('Good morning!') }, window: window)
  no = findings(GREETING, greeting('Good evening.'), Array.new(7) { greeting('Good evening.') }, window: window)
  expect(ok.empty? && no.any? { |f| f.include?('greeting_disagrees_with_run_clock') }, "#{ok.inspect} / #{no.inspect}")
end

# ============================================================== errors ======

ERRORS = '_content/tour/methods/errors.go'
def error_line(stamp)
  observation("at #{stamp}, it didn't work\n")
end
ERRORS_ORACLE = (0...7).map { |i| error_line(go_stamp(i * 0.5, monotonic: "0.00007#{i}")) }

accepts('go_time_error_line: a timestamp inside the recorded run window', ERRORS, error_line(go_stamp(2.0)), ERRORS_ORACLE)
rejects('go_time_error_line: rejects altered surrounding text', ERRORS,
        observation("at #{go_stamp(2.0)}, it worked\n"), ERRORS_ORACLE, 'shape')
rejects('go_time_error_line: rejects a timestamp OUTSIDE the recorded run window', ERRORS,
        error_line(go_stamp(-86_400.0)), ERRORS_ORACLE, 'outside_run_window')
rejects('go_time_error_line: rejects a missing monotonic reading', ERRORS,
        error_line(go_stamp(2.0, monotonic: nil)), ERRORS_ORACLE, 'no_monotonic_reading')
rejects('go_time_error_line: rejects an implausible monotonic reading', ERRORS,
        error_line(go_stamp(2.0, monotonic: '3600.0')), ERRORS_ORACLE, 'monotonic_out_of_range')
rejects('go_time_error_line: rejects a value that is not a Go timestamp at all', ERRORS,
        error_line('some time yesterday'), ERRORS_ORACLE, 'not_a_go_timestamp')
rejects('go_time_error_line: rejects an extra line', ERRORS,
        observation("at #{go_stamp(2.0)}, it didn't work\nand again\n"), ERRORS_ORACLE, 'line_count')

# ============================================================= sandbox ======

SANDBOX = '_content/tour/welcome/sandbox.go'
def sandbox(stamp, greeting: 'Welcome to the playground!')
  observation("#{greeting}\nThe time is #{stamp}\n")
end
SANDBOX_ORACLE = (0...7).map { |i| sandbox(go_stamp(i * 0.5, monotonic: "0.00008#{i}")) }

accepts('sandbox_time: greeting plus a timestamp inside the run window', SANDBOX, sandbox(go_stamp(3.0)), SANDBOX_ORACLE)
rejects('sandbox_time: rejects an altered greeting', SANDBOX,
        sandbox(go_stamp(3.0), greeting: 'Welcome to the sandbox!'), SANDBOX_ORACLE, 'greeting')
rejects('sandbox_time: rejects a timestamp outside the run window', SANDBOX,
        sandbox(go_stamp(99_999.0)), SANDBOX_ORACLE, 'outside_run_window')
rejects('sandbox_time: rejects a non-timestamp', SANDBOX, sandbox('now'), SANDBOX_ORACLE, 'not_a_go_timestamp')

# ============================================================ line_set ======

STRINGER = '_content/tour/methods/exercise-stringer.go'
STRINGERS = '_content/tour/solutions/stringers.go'
LOOPBACK = 'loopback: [127 0 0 1]'
GOOGLE = 'googleDNS: [8 8 8 8]'
def two(lines)
  observation(lines.map { |l| "#{l}\n" }.join)
end
STRINGER_ORACLE = [two([LOOPBACK, GOOGLE]), two([GOOGLE, LOOPBACK])] * 4

accepts('line_set: accepts either map iteration order', STRINGER, two([GOOGLE, LOOPBACK]), STRINGER_ORACLE)
accepts('line_set: accepts the other order too', STRINGER, two([LOOPBACK, GOOGLE]), STRINGER_ORACLE)
rejects('line_set: rejects a duplicated line', STRINGER, two([LOOPBACK, LOOPBACK]), STRINGER_ORACLE, 'duplicate_lines')
rejects('line_set: rejects a missing line', STRINGER, two([LOOPBACK]), STRINGER_ORACLE, 'line_count')
rejects('line_set: rejects an extra line', STRINGER, two([LOOPBACK, GOOGLE, 'extra: [1 2 3 4]']), STRINGER_ORACLE, 'line_count')
rejects('line_set: rejects a WRONG VALUE, not just a wrong order', STRINGER,
        two([LOOPBACK, 'googleDNS: [8 8 8 9]']), STRINGER_ORACLE, 'unexpected_lines')
rejects('line_set: rejects the sibling row\'s rendering (String() vs raw array)', STRINGER,
        two(['loopback: 127.0.0.1', 'googleDNS: 8.8.8.8']), STRINGER_ORACLE, 'unexpected_lines')
check('line_set: the two bound rows expect DIFFERENT renderings') do
  stringers_oracle = Array.new(8) { two(['loopback: 127.0.0.1', 'googleDNS: 8.8.8.8']) }
  ok = findings(STRINGERS, two(['googleDNS: 8.8.8.8', 'loopback: 127.0.0.1']), stringers_oracle)
  crossed = findings(STRINGERS, two([LOOPBACK, GOOGLE]), stringers_oracle)
  expect(ok.empty? && crossed.any? { |f| f.include?('unexpected_lines') }, "#{ok.inspect} / #{crossed.inspect}")
end

# ========================================================== webcrawler ======

CRAWLER = '_content/tour/solutions/webcrawler.go'
CRAWL_SAMPLE = <<~CRAWL
  Found: https://golang.org/ "The Go Programming Language"
  -> Crawling child 0/2 of https://golang.org/ : https://golang.org/pkg/.
  -> Crawling child 1/2 of https://golang.org/ : https://golang.org/cmd/.
  <- [https://golang.org/] 0/2 Waiting for child https://golang.org/pkg/.
  Found: https://golang.org/pkg/ "Packages"
  -> Crawling child 0/4 of https://golang.org/pkg/ : https://golang.org/.
  <- Error on https://golang.org/cmd/: not found: https://golang.org/cmd/
  <- [https://golang.org/] 1/2 Waiting for child https://golang.org/cmd/.
  -> Crawling child 1/4 of https://golang.org/pkg/ : https://golang.org/cmd/.
  -> Crawling child 2/4 of https://golang.org/pkg/ : https://golang.org/pkg/fmt/.
  -> Crawling child 3/4 of https://golang.org/pkg/ : https://golang.org/pkg/os/.
  <- [https://golang.org/pkg/] 0/4 Waiting for child https://golang.org/.
  Found: https://golang.org/pkg/os/ "Package os"
  -> Crawling child 0/2 of https://golang.org/pkg/os/ : https://golang.org/.
  -> Crawling child 1/2 of https://golang.org/pkg/os/ : https://golang.org/pkg/.
  <- [https://golang.org/pkg/os/] 0/2 Waiting for child https://golang.org/.
  <- Done with https://golang.org/pkg/, already fetched.
  <- [https://golang.org/pkg/os/] 1/2 Waiting for child https://golang.org/pkg/.
  <- Done with https://golang.org/, already fetched.
  <- Done with https://golang.org/pkg/os/
  <- [https://golang.org/pkg/] 1/4 Waiting for child https://golang.org/cmd/.
  <- Done with https://golang.org/, already fetched.
  <- [https://golang.org/pkg/] 2/4 Waiting for child https://golang.org/pkg/fmt/.
  <- Done with https://golang.org/cmd/, already fetched.
  <- [https://golang.org/pkg/] 3/4 Waiting for child https://golang.org/pkg/os/.
  Found: https://golang.org/pkg/fmt/ "Package fmt"
  -> Crawling child 0/2 of https://golang.org/pkg/fmt/ : https://golang.org/.
  -> Crawling child 1/2 of https://golang.org/pkg/fmt/ : https://golang.org/pkg/.
  <- [https://golang.org/pkg/fmt/] 0/2 Waiting for child https://golang.org/.
  <- Done with https://golang.org/pkg/, already fetched.
  <- [https://golang.org/pkg/fmt/] 1/2 Waiting for child https://golang.org/pkg/.
  <- Done with https://golang.org/, already fetched.
  <- Done with https://golang.org/pkg/fmt/
  <- Done with https://golang.org/pkg/
  <- Done with https://golang.org/
  Fetching stats
  --------------
  https://golang.org/ was fetched
  https://golang.org/cmd/ failed: not found: https://golang.org/cmd/
  https://golang.org/pkg/ was fetched
  https://golang.org/pkg/os/ was fetched
  https://golang.org/pkg/fmt/ was fetched
CRAWL

def crawl(text = CRAWL_SAMPLE)
  observation(text)
end

# Native variation changes independent event/statistics order, never graph edges.
CRAWL_ORACLE = (0...7).map do |i|
  lines = CRAWL_SAMPLE.lines
  lines[-5, 5] = lines[-5, 5].reverse if i.odd?
  crawl(lines.join)
end

accepts('webcrawler_crawl: a real concurrent crawl', CRAWLER, crawl, CRAWL_ORACLE)
rejects('webcrawler_crawl: rejects a missing statistics entry', CRAWLER,
        crawl(CRAWL_SAMPLE.sub("https://golang.org/pkg/os/ was fetched\n", '')), CRAWL_ORACLE, 'stats_missing')
rejects('webcrawler_crawl: rejects an invented statistics entry', CRAWLER,
        crawl(CRAWL_SAMPLE + "https://golang.org/doc/ was fetched\n"), CRAWL_ORACLE, 'stats_unexpected')
rejects('webcrawler_crawl: rejects a duplicated statistics entry', CRAWLER,
        crawl(CRAWL_SAMPLE + "https://golang.org/ was fetched\n"), CRAWL_ORACLE, 'stats_duplicate')
rejects('webcrawler_crawl: rejects a WRONG PAGE BODY', CRAWLER,
        crawl(CRAWL_SAMPLE.sub('"Package fmt"', '"Package format"')), CRAWL_ORACLE, 'found_body')
rejects('webcrawler_crawl: rejects a page found twice (multiplicity)', CRAWLER,
        crawl(CRAWL_SAMPLE.sub("Found: https://golang.org/pkg/ \"Packages\"\n",
                               "Found: https://golang.org/pkg/ \"Packages\"\nFound: https://golang.org/pkg/ \"Packages\"\n")),
        CRAWL_ORACLE, 'found_multiplicity')
rejects('webcrawler_crawl: rejects waiting for a child that was never crawled (causal order)', CRAWLER,
        crawl(CRAWL_SAMPLE.sub("-> Crawling child 0/2 of https://golang.org/ : https://golang.org/pkg/.\n", '')),
        CRAWL_ORACLE, 'causal_order')
rejects('webcrawler_crawl: rejects an unpaired crawl/wait edge', CRAWLER,
        crawl(CRAWL_SAMPLE.sub("<- [https://golang.org/] 1/2 Waiting for child https://golang.org/cmd/.\n", '')),
        CRAWL_ORACLE, 'child_wait_pairing')
rejects('webcrawler_crawl: rejects an unknown URL', CRAWLER,
        crawl(CRAWL_SAMPLE.sub('Found: https://golang.org/pkg/os/ "Package os"',
                               'Found: https://golang.org/pkg/net/ "Package os"')),
        CRAWL_ORACLE, 'unknown_url')
rejects('webcrawler_crawl: rejects an unparseable line', CRAWLER,
        crawl(CRAWL_SAMPLE.sub("Fetching stats\n", "surprise\nFetching stats\n")), CRAWL_ORACLE, 'unparsed_line')
rejects('webcrawler_crawl: rejects a missing error observation for the unfetchable URL', CRAWLER,
        crawl(CRAWL_SAMPLE.sub("<- Error on https://golang.org/cmd/: not found: https://golang.org/cmd/\n", '')),
        CRAWL_ORACLE, 'error_multiplicity')

rejects('tick: rejects 100 zero-time default events', SELECT,
        tick_run(Array.new(100) { [0, :default] } + SELECT_GOOD), SELECT_ORACLE, 'default_sleep_missing')
rejects('tick: rejects compressed sleep even with legal counts', SELECT,
        tick_run(SELECT_GOOD.map.with_index { |event, i| i == 1 ? [1, :default] : event }), SELECT_ORACLE, 'default_sleep_missing')
rejects('crawler: rejects unknown already-fetched URL', CRAWLER,
        crawl(CRAWL_SAMPLE.sub('<- Done with https://golang.org/pkg/, already fetched.', '<- Done with https://wrong.invalid/, already fetched.')), CRAWL_ORACLE, 'unknown_url')
rejects('crawler: rejects paired but impossible topology', CRAWLER,
        crawl(CRAWL_SAMPLE.sub('0/2 of https://golang.org/ :', '99/200 of https://wrong.invalid/ :').sub('[https://golang.org/] 0/2 Waiting', '[https://wrong.invalid/] 99/200 Waiting')), CRAWL_ORACLE, 'crawl_topology')
rejects('crawler: rejects an extra terminal event for an unknown URL', CRAWLER,
        crawl(CRAWL_SAMPLE.sub("Fetching stats\n", "<- Done with https://wrong.invalid/\nFetching stats\n")), CRAWL_ORACLE, 'unknown_done_url')
rejects('crawler: rejects duplicate already-fetched event', CRAWLER,
        crawl(CRAWL_SAMPLE.sub('Fetching stats', "<- Done with https://golang.org/pkg/, already fetched.\nFetching stats")), CRAWL_ORACLE, 'already_multiplicity')

# ====================================================== cross-rejection =====
#
# A comparator must not accept another row's output. This is the property that
# makes the set NARROW rather than a family of permissive shape checks.

SAMPLES = {
  PACKAGES => packages_line(3),
  GOROUTINES => say(%w[hello world hello world hello world hello world hello]),
  SELECT => tick_run(SELECT_GOOD),
  WEEKDAY => weekday('Too far away.'),
  GREETING => greeting('Good evening.'),
  ERRORS => error_line(go_stamp(2.0)),
  STRINGER => two([LOOPBACK, GOOGLE]),
  CRAWLER => crawl,
  SANDBOX => sandbox(go_stamp(3.0))
}.freeze

ORACLES = {
  PACKAGES => PACKAGES_ORACLE, GOROUTINES => GOROUTINES_ORACLE, SELECT => SELECT_ORACLE,
  WEEKDAY => WEEKDAY_ORACLE, GREETING => GREETING_ORACLE, ERRORS => ERRORS_ORACLE,
  STRINGER => STRINGER_ORACLE, CRAWLER => CRAWL_ORACLE, SANDBOX => SANDBOX_ORACLE
}.freeze

SAMPLES.each_key do |target|
  SAMPLES.each do |other, sample|
    next if other == target
    check("cross: #{TABLE.fetch(target)['comparator']} rejects the output of #{File.basename(other)}") do
      got = findings(target, sample, ORACLES.fetch(target))
      expect(!got.empty?, 'accepted another row\'s output')
    end
  end
end

# ========================================================= table binding ====

check('table: every declared-volatile row has exactly one comparator') do
  expect(TABLE.length == 10, "#{TABLE.length} rows")
end

check('table: a comparator cannot be bound to a row whose pinned digest differs') do
  inventory = TABLE.keys.to_h { |path| [path, { 'sha256' => 'f' * 64 }] }
  begin
    TourSemantics.load_table(File.join(ROOT, 'docs/tour/semantics.tsv'), inventory: inventory)
    'accepted a mismatched source digest'
  rescue TourSemantics::TableError
    true
  end
end

check('table: an unknown comparator name is rejected') do
  Dir.mktmpdir do |dir|
    path = File.join(dir, 'semantics.tsv')
    File.write(path, "a.go\tmagic_pass\t#{'a' * 64}\trequired\tx\t{}\n")
    begin
      TourSemantics.load_table(path)
      'accepted an unknown comparator'
    rescue TourSemantics::TableError
      true
    end
  end
end

check('table: a row outside the executable inventory is rejected') do
  begin
    TourSemantics.load_table(File.join(ROOT, 'docs/tour/semantics.tsv'), inventory: {})
    'accepted a row that is not an executable inventory row'
  rescue TourSemantics::TableError
    true
  end
end

puts "tour semantic comparator selftests: #{PASSED.length} passed, #{FAILED.length} failed"
FAILED.each { |f| warn "  FAIL #{f}" }
exit(FAILED.empty? ? 0 : 1)
