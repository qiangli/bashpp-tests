#!/usr/bin/env ruby
# frozen_string_literal: true
#
# Narrow semantic comparators for the declared-volatile tour rows.
#
# Sprint 118 / Story #4 / Story-ID 759341a95870.
#
# WHAT THIS IS. Ten rows of the pinned tour executable denominator cannot
# reproduce a byte-exact digest because their output depends on the wall clock,
# the randomly seeded global PRNG, goroutine interleaving or Go's randomized
# map iteration order (docs/tour/volatility.tsv, measured over seven runs per
# row). The sprint-118 plan §6 allows exactly two ways out: a real environment
# control, or an EXPLICIT, REVIEWED SEMANTIC COMPARATOR that verifies values,
# ranges, event multiplicity, causal order and timing conditions. The original
# story (2daf) permits checked-in deterministic adapters or narrow normalizers
# provided the upstream source is unchanged. This file is that comparator set.
# The upstream sources are untouched; each comparator is bound to one pinned
# source digest and can never be applied to another program.
#
# WHAT THIS IS NOT. It is not a mask. No comparator returns true unconditionally,
# none of them widens tools/tour/normalize.rb, and none of them hides a value,
# a count, an order or a status:
#
#   * exit status and stderr are compared EXACTLY against the oracle in every
#     case; only stdout is adjudicated semantically, and only for the elements
#     docs/tour/semantics.tsv names as volatile;
#   * every invariant is also applied to every ORACLE observation, so a
#     comparator that is too loose to describe the real program, or too tight
#     to admit it, fails on the oracle before it can excuse a candidate;
#   * ranges and multiplicities are taken from ACTUAL REPEATED NATIVE
#     OBSERVATIONS of the freshly built binary for that row, not from a frozen
#     historical draw;
#   * tools/tour/semantics-selftests.rb drives each comparator with wrong
#     values, wrong counts, wrong order, wrong status and wrong timing and
#     requires rejection.
#
# THE ORACLE. `oracle` is a list of observations of the CURRENT native binary
# built from the unchanged upstream source in this run — the same artifact the
# baseline stage executed, bound by digest in the ledger. The historical
# accepted digest in tests/tour/results.tsv stays in evidence as HISTORICAL: it
# records one draw of a nondeterministic program on one day and is no longer
# treated as a required output for these ten rows.
#
# THE WINDOW. Clock-dependent rows are adjudicated against the wall-clock
# interval in which the observations were actually taken, recorded in the
# ledger, never against `Time.now` at audit time — otherwise the gate would not
# be reproducible offline. The window's own credibility is the gate's business
# (it bounds the window's length and containment); here it is an input.

require 'json'
require 'time'

module TourSemantics
  VERSION = 'tour-semantics/v1'

  # Fewer repeats than this cannot establish a range or a multiplicity, so a
  # thin oracle is a failure rather than a licence.
  MIN_ORACLE_RUNS = 5

  # Go's time.Time default layout, as printed by fmt for a native run:
  #   2026-09-08 21:19:44.164138 -0700 PDT m=+0.000073835
  GO_TIME = /\A(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}(?:\.\d{1,9})? [+-]\d{4}) (\S+)(?: m=([+-]\d+(?:\.\d+)?))?\z/
  # A native program prints its error/clock line immediately; a monotonic
  # reading far from zero means the recorded line did not come from this run.
  MAX_MONOTONIC_SECONDS = 60.0
  # Slack around the recorded window for a wall-clock comparison.
  CLOCK_SLACK_SECONDS = 120.0

  COMPARATORS = %w[rand_intn_line say_interleaving tick_boom_sequence weekday_switch
                   hour_greeting go_time_error_line line_set webcrawler_crawl sandbox_time].freeze
  BURST_VARIATION = %w[required not_required].freeze

  class TableError < StandardError; end

  module_function

  # ------------------------------------------------------------------ table

  # docs/tour/semantics.tsv:
  #   path  comparator  source_sha256  burst_variation  volatile_element  params
  #
  # `source_sha256` binds a comparator to ONE pinned program. `inventory`, when
  # supplied, is checked against it, so a comparator cannot be retargeted at a
  # different (easier) row by editing the path column alone.
  def load_table(path, inventory: nil)
    rows = File.readlines(path, chomp: true).reject { |l| l.start_with?('#') || l.empty? }
    table = {}
    rows.each do |line|
      source, comparator, sha, variation, element, params = line.split("\t", -1)
      raise TableError, "semantics: unknown comparator #{comparator.inspect}" unless COMPARATORS.include?(comparator)
      raise TableError, "semantics: bad burst_variation #{variation.inspect}" unless BURST_VARIATION.include?(variation)
      raise TableError, "semantics: duplicate row #{source}" if table.key?(source)
      raise TableError, "semantics: #{source} has no source digest" unless sha.to_s.length == 64
      if inventory && inventory[source]
        raise TableError, "semantics: #{source} digest does not match the inventory" unless inventory[source]['sha256'] == sha
      elsif inventory
        raise TableError, "semantics: #{source} is not an executable inventory row"
      end
      decoded =
        begin
          JSON.parse(params)
        rescue JSON::ParserError => e
          raise TableError, "semantics: #{source} params are not JSON: #{e.message}"
        end
      table[source] = { 'path' => source, 'comparator' => comparator, 'source_sha256' => sha,
                        'burst_variation' => variation, 'volatile_element' => element, 'params' => decoded }
    end
    table
  end

  # ------------------------------------------------------------- comparison

  # candidate/oracle entries: { 'exit' => Integer|nil, 'stdout' => String,
  #                             'stderr' => String }  (streams already decoded)
  # window: { 'from' => epoch_float, 'to' => epoch_float, 'utc_offset' => secs }
  def compare(row, candidate:, oracle:, window:)
    comparator = row.fetch('comparator')
    params = row.fetch('params')
    findings = []
    findings << "oracle:insufficient_runs:#{oracle.length}<#{MIN_ORACLE_RUNS}" if oracle.length < MIN_ORACLE_RUNS

    # 1. status and stderr are never adjudicated semantically.
    exits = oracle.map { |o| o['exit'] }.uniq
    findings << "oracle:unstable_exit:#{exits.inspect}" unless exits.length == 1
    findings << "status:exit_mismatch:#{candidate['exit'].inspect}!=#{exits.first.inspect}" unless exits.length == 1 && candidate['exit'] == exits.first
    stderrs = oracle.map { |o| o['stderr'].to_s }.uniq
    findings << 'oracle:unstable_stderr' unless stderrs.length == 1
    findings << 'stderr:mismatch' unless stderrs.length == 1 && candidate['stderr'].to_s == stderrs.first

    # 2. the comparator must describe every oracle observation of the real
    #    program, or it is the wrong comparator.
    oracle_facts = oracle.each_with_index.map do |observation, i|
      facts = facts(comparator, observation['stdout'].to_s, params)
      facts.fetch('findings').each { |f| findings << "oracle:invariant_violation:#{i}:#{f}" }
      facts
    end

    # 3. the candidate's own invariants.
    candidate_facts = facts(comparator, candidate['stdout'].to_s, params)
    candidate_facts.fetch('findings').each { |f| findings << "stdout:#{f}" }

    # 4. cross-observation reconciliation: support, ranges, multiplicities,
    #    agreement and timing conditions against the native repeats.
    if candidate_facts.fetch('findings').empty? && oracle_facts.all? { |f| f.fetch('findings').empty? }
      reconcile(comparator, candidate_facts, oracle_facts, params, window).each { |f| findings << f }
    end

    # 5. a comparator is only warranted where nondeterminism is real. Where the
    #    volatile element must vary inside a single burst (a PRNG draw, a
    #    goroutine interleaving, a nanosecond clock), an oracle that produced
    #    one single distinct stdout is evidence the comparator is not needed
    #    here and is therefore hiding something.
    distinct = oracle.map { |o| o['stdout'].to_s }.uniq.length
    if row.fetch('burst_variation') == 'required' && distinct < 2 && oracle.length >= MIN_ORACLE_RUNS
      findings << "oracle:no_variation_observed:#{distinct}"
    end

    { 'comparator' => comparator, 'version' => VERSION, 'ok' => findings.empty?,
      'findings' => findings.sort,
      'evidence' => { 'oracle_runs' => oracle.length, 'oracle_distinct_stdout' => distinct,
                      'candidate' => summarize(candidate_facts), 'oracle' => oracle_facts.map { |f| summarize(f) } } }
  end

  def summarize(facts)
    facts.reject { |key, _| key == 'findings' }
  end

  # -------------------------------------------------------------- utilities

  def split_lines(text, findings)
    return [] if text.empty?
    unless text.end_with?("\n")
      findings << 'unterminated_output'
      return text.split("\n", -1)
    end
    text[0..-2].split("\n", -1)
  end

  DURATION = /\A(\d+(?:\.\d+)?)(ns|us|µs|ms|s|m)\z/
  def duration_ms(token)
    m = DURATION.match(token)
    return nil unless m
    scale = { 'ns' => 1e-6, 'us' => 1e-3, 'µs' => 1e-3, 'ms' => 1.0, 's' => 1000.0, 'm' => 60_000.0 }
    m[1].to_f * scale.fetch(m[2])
  end

  # Parses the wall-clock half of a Go time.Time rendering into an epoch and
  # returns it with the monotonic reading, or nil when the layout is wrong.
  def go_time(token)
    m = GO_TIME.match(token)
    return nil unless m
    stamp = m[1]
    format = stamp.include?('.') ? '%Y-%m-%d %H:%M:%S.%N %z' : '%Y-%m-%d %H:%M:%S %z'
    begin
      wall = Time.strptime(stamp, format)
    rescue ArgumentError
      return nil
    end
    { 'epoch' => wall.to_f, 'zone' => m[2], 'monotonic' => m[3] && m[3].to_f }
  end

  def clock_findings(stamp, window, label)
    findings = []
    parsed = go_time(stamp)
    return ["#{label}:not_a_go_timestamp:#{stamp.inspect}"] if parsed.nil?
    findings << "#{label}:no_monotonic_reading" if parsed['monotonic'].nil?
    if parsed['monotonic'] && parsed['monotonic'].abs > MAX_MONOTONIC_SECONDS
      findings << "#{label}:monotonic_out_of_range:#{parsed['monotonic']}"
    end
    from = window.fetch('from') - CLOCK_SLACK_SECONDS
    to = window.fetch('to') + CLOCK_SLACK_SECONDS
    findings << "#{label}:outside_run_window:#{parsed['epoch']}" unless parsed['epoch'].between?(from, to)
    findings
  end

  def window_times(window)
    offset = window['utc_offset']
    [window.fetch('from'), window.fetch('to')].map do |epoch|
      offset ? Time.at(epoch).getlocal(offset) : Time.at(epoch)
    end
  end

  def range_finding(label, value, values)
    return [] if values.empty?
    low, high = values.min, values.max
    return [] if value.between?(low, high)
    ["#{label}:#{value}_outside_native_range_#{low}..#{high}"]
  end

  # ------------------------------------------------------------ invariants

  # Returns { 'findings' => [...], plus comparator-specific facts }.
  def facts(comparator, text, params)
    result = { 'findings' => [] }
    lines = split_lines(text, result['findings'])
    send("facts_#{comparator}", lines, params, result)
    result
  end

  def reconcile(comparator, candidate, oracle, params, window)
    send("reconcile_#{comparator}", candidate, oracle, params, window)
  end

  # -- basics/packages.go: `fmt.Println("My favorite number is", rand.Intn(10))`
  #
  # The volatile element is one PRNG draw. Its declared support is exactly the
  # support of rand.Intn(10): the integers 0..9. Any other value, any other
  # text and any other line count is a failure.
  def facts_rand_intn_line(lines, params, result)
    prefix = params.fetch('prefix')
    if lines.length != 1
      result['findings'] << "line_count:#{lines.length}!=1"
      return
    end
    match = /\A#{Regexp.escape(prefix)}(0|[1-9]\d*)\z/.match(lines[0])
    unless match
      result['findings'] << "shape:#{lines[0].inspect}"
      return
    end
    value = Integer(match[1])
    result['value'] = value
    bound = params.fetch('modulus')
    result['findings'] << "value_outside_support:#{value}_not_in_0...#{bound}" unless (0...bound).cover?(value)
  end

  def reconcile_rand_intn_line(_candidate, _oracle, _params, _window)
    # The declared SUPPORT, not the observed sample, is the contract here: a
    # draw the oracle happened not to produce is still a legal draw. What the
    # oracle has to establish is that the value really is drawn (burst_variation
    # above) and that every native draw also lands in 0...modulus (checked as
    # an invariant on every oracle observation).
    []
  end

  # -- concurrency/goroutines.go: `go say("world"); say("hello")`
  #
  # main prints its own value exactly five times and then returns, killing the
  # goroutine wherever it got to. So the MAIN multiplicity is exact, the
  # GOROUTINE multiplicity is a range bounded by the native repeats, the line
  # vocabulary is closed, and only the interleaving is free.
  def facts_say_interleaving(lines, params, result)
    values = params.fetch('values')
    counts = Hash.new(0)
    lines.each { |line| counts[line] += 1 }
    unknown = counts.keys - values
    result['findings'] << "unknown_line:#{unknown.sort.inspect}" unless unknown.empty?
    result['counts'] = values.to_h { |value| [value, counts[value]] }
    main, expected = params.fetch('main'), params.fetch('main_count')
    result['findings'] << "main_multiplicity:#{counts[main]}!=#{expected}" unless counts[main] == expected
    goroutine = counts[params.fetch('goroutine')]
    result['goroutine_count'] = goroutine
    result['findings'] << "goroutine_multiplicity_outside_bound:#{goroutine}>#{expected}" if goroutine > expected
  end

  def reconcile_say_interleaving(candidate, oracle, _params, _window)
    range_finding('goroutine_multiplicity', candidate['goroutine_count'], oracle.map { |o| o['goroutine_count'] })
  end

  # -- concurrency/default-selection.go: a 100ms tick, a 500ms boom, a default
  #    branch that sleeps 50ms, all stamped with the rounded elapsed time.
  #
  # Verified: the line grammar, event multiplicity (exactly one BOOM, at least
  # one default selection, a tick count inside the native range), causal order
  # (BOOM is final, elapsed never goes backwards) and timing conditions (the
  # i-th tick cannot precede i*100ms, BOOM cannot precede 500ms).
  TICK_LINE = /\A\[\s*([0-9][^\]]*)\]\s+(tick\.|BOOM!|\.)\z/
  def facts_tick_boom_sequence(lines, params, result)
    if lines.empty?
      result['findings'] << 'no_output'
      return
    end
    events = []
    lines.each_with_index do |line, i|
      match = TICK_LINE.match(line)
      unless match
        result['findings'] << "unparsed_line:#{i}:#{line.inspect}"
        next
      end
      ms = duration_ms(match[1])
      if ms.nil?
        result['findings'] << "unparsed_elapsed:#{i}:#{match[1].inspect}"
        next
      end
      events << [ms, { 'tick.' => 'tick', 'BOOM!' => 'boom', '.' => 'default' }.fetch(match[2])]
    end
    return unless result['findings'].empty?

    kinds = events.map(&:last)
    result['tick_count'] = kinds.count('tick')
    result['default_count'] = kinds.count('default')
    booms = kinds.count('boom')
    result['findings'] << "boom_multiplicity:#{booms}!=1" unless booms == 1
    result['findings'] << 'boom_not_final' unless kinds.last == 'boom'
    result['findings'] << 'no_default_selection' if result['default_count'].zero?
    elapsed = events.map(&:first)
    elapsed.each_cons(2).with_index do |(a, b), i|
      result['findings'] << "elapsed_not_monotonic:#{i}:#{a}>#{b}" if a > b
    end
    events.each_cons(2).with_index do |((ms, kind), (following, _)), i|
      next unless kind == 'default'
      floor = params.fetch('default_sleep_ms') - params.fetch('rounding_slack_ms')
      result['findings'] << "default_sleep_missing:#{i}:#{following - ms}<#{floor}" if following - ms < floor
    end
    events.select { |_, kind| kind == 'tick' }.each_with_index do |(ms, _), i|
      floor = params.fetch('tick_ms') * (i + 1)
      result['findings'] << "tick_early:#{i}:#{ms}<#{floor}" if ms < floor
    end
    boom = events.find { |_, kind| kind == 'boom' }
    if boom
      result['boom_ms'] = boom.first
      result['findings'] << "boom_early:#{boom.first}<#{params.fetch('boom_ms')}" if boom.first < params.fetch('boom_ms')
    end
    result['line_count'] = lines.length
  end

  def reconcile_tick_boom_sequence(candidate, oracle, params, _window)
    findings = range_finding('tick_count', candidate['tick_count'], oracle.map { |o| o['tick_count'] })
    findings.concat(range_finding('default_count', candidate['default_count'], oracle.map { |o| o['default_count'] }))
    ceiling = oracle.map { |o| o['boom_ms'].to_f }.max + params.fetch('boom_slack_ms')
    findings << "boom_late:#{candidate['boom_ms']}>#{ceiling}" if candidate['boom_ms'].to_f > ceiling
    findings
  end

  # -- flowcontrol/switch-evaluation-order.go: prints the distance to Saturday.
  #
  # The value set is closed AND the value is COMPUTED from the recorded run
  # window: a member of the set that disagrees with the clock the run actually
  # had is rejected. Both window endpoints are admitted so a midnight rollover
  # inside the window is honest rather than a coin flip.
  WEEKDAY_ANSWER = { 6 => 'Today.', 5 => 'Tomorrow.', 4 => 'In two days.' }.freeze
  def facts_weekday_switch(lines, params, result)
    prompt, values = params.fetch('prompt'), params.fetch('values')
    if lines.length != 2
      result['findings'] << "line_count:#{lines.length}!=2"
      return
    end
    result['findings'] << "prompt:#{lines[0].inspect}" unless lines[0] == prompt
    result['answer'] = lines[1]
    result['findings'] << "answer_outside_value_set:#{lines[1].inspect}" unless values.include?(lines[1])
  end

  def reconcile_weekday_switch(candidate, oracle, _params, window)
    findings = []
    answers = oracle.map { |o| o['answer'] }.uniq
    findings << "oracle:disagreement:#{answers.inspect}" unless answers.length == 1
    findings << "answer_disagrees_with_oracle:#{candidate['answer'].inspect}" unless answers == [candidate['answer']]
    expected = window_times(window).map { |t| WEEKDAY_ANSWER.fetch(t.wday, 'Too far away.') }.uniq
    unless expected.include?(candidate['answer'])
      findings << "answer_disagrees_with_run_clock:#{candidate['answer'].inspect}!=#{expected.inspect}"
    end
    findings
  end

  # -- flowcontrol/switch-with-no-condition.go: the hour-of-day greeting.
  def facts_hour_greeting(lines, params, result)
    values = params.fetch('values')
    if lines.length != 1
      result['findings'] << "line_count:#{lines.length}!=1"
      return
    end
    result['greeting'] = lines[0]
    result['findings'] << "greeting_outside_value_set:#{lines[0].inspect}" unless values.include?(lines[0])
  end

  def reconcile_hour_greeting(candidate, oracle, params, window)
    findings = []
    greetings = oracle.map { |o| o['greeting'] }.uniq
    findings << "oracle:disagreement:#{greetings.inspect}" unless greetings.length == 1
    findings << "greeting_disagrees_with_oracle:#{candidate['greeting'].inspect}" unless greetings == [candidate['greeting']]
    morning, afternoon, evening = params.fetch('values')
    expected = window_times(window).map do |t|
      if t.hour < params.fetch('morning_before') then morning
      elsif t.hour < params.fetch('afternoon_before') then afternoon
      else evening
      end
    end.uniq
    unless expected.include?(candidate['greeting'])
      findings << "greeting_disagrees_with_run_clock:#{candidate['greeting'].inspect}!=#{expected.inspect}"
    end
    findings
  end

  # -- methods/errors.go: `at <time.Now()>, it didn't work`.
  #
  # Only the timestamp field is volatile. Its shape, its monotonic reading and
  # its position inside the recorded run window are all checked; every other
  # byte of the line is exact.
  def facts_go_time_error_line(lines, params, result)
    if lines.length != 1
      result['findings'] << "line_count:#{lines.length}!=1"
      return
    end
    match = /\A#{Regexp.escape(params.fetch('prefix'))}(.+)#{Regexp.escape(params.fetch('suffix'))}\z/.match(lines[0])
    unless match
      result['findings'] << "shape:#{lines[0].inspect}"
      return
    end
    result['timestamp'] = match[1]
    result['findings'] << "timestamp:not_a_go_timestamp:#{match[1].inspect}" if go_time(match[1]).nil?
  end

  def reconcile_go_time_error_line(candidate, _oracle, _params, window)
    clock_findings(candidate.fetch('timestamp'), window, 'timestamp')
  end

  # -- welcome/sandbox.go: a fixed greeting plus `The time is <time.Now()>`.
  def facts_sandbox_time(lines, params, result)
    if lines.length != 2
      result['findings'] << "line_count:#{lines.length}!=2"
      return
    end
    result['findings'] << "greeting:#{lines[0].inspect}" unless lines[0] == params.fetch('greeting')
    prefix = params.fetch('prefix')
    unless lines[1].start_with?(prefix)
      result['findings'] << "shape:#{lines[1].inspect}"
      return
    end
    result['timestamp'] = lines[1].delete_prefix(prefix)
    result['findings'] << "timestamp:not_a_go_timestamp:#{result['timestamp'].inspect}" if go_time(result['timestamp']).nil?
  end

  def reconcile_sandbox_time(candidate, _oracle, _params, window)
    clock_findings(candidate.fetch('timestamp'), window, 'timestamp')
  end

  # -- methods/exercise-stringer.go and solutions/stringers.go: a range over a
  #    two-entry map, whose iteration order Go randomizes per process.
  #
  # ONLY the order is free. The line set is exact, every line must appear
  # exactly once, and the rendered values are compared literally — a wrong
  # octet or a wrong format is a failure, not an ordering difference.
  def facts_line_set(lines, params, result)
    expected = params.fetch('lines')
    counts = Hash.new(0)
    lines.each { |line| counts[line] += 1 }
    result['line_count'] = lines.length
    result['findings'] << "line_count:#{lines.length}!=#{expected.length}" unless lines.length == expected.length
    duplicated = counts.select { |_, n| n > 1 }.keys.sort
    result['findings'] << "duplicate_lines:#{duplicated.inspect}" unless duplicated.empty?
    missing = expected - lines
    extra = lines - expected
    result['findings'] << "missing_lines:#{missing.inspect}" unless missing.empty?
    result['findings'] << "unexpected_lines:#{extra.inspect}" unless extra.empty?
    result['order'] = lines
  end

  def reconcile_line_set(_candidate, _oracle, _params, _window)
    []
  end

  # -- solutions/webcrawler.go: a concurrent crawl of a canned fetcher.
  #
  # Verified: the closed URL vocabulary; the exact body of every fetched page;
  # multiplicity (each page found once, each page done once, exactly one error
  # for the unfetchable URL); the pairing of every `-> Crawling child` line with
  # its `<- Waiting for child` line; the causal order of each such pair; and the
  # complete, exact final statistics block. Only the interleaving of independent
  # goroutines and the final map iteration are free. The pinned graph fixes
  # every edge and each URL's already-fetched multiplicity.
  CRAWL_FOUND = /\AFound: (\S+) "(.*)"\z/.freeze
  CRAWL_CHILD = /\A-> Crawling child (\d+)\/(\d+) of (\S+) : (\S+)\.\z/.freeze
  CRAWL_WAIT = /\A<- \[(\S+)\] (\d+)\/(\d+) Waiting for child (\S+)\.\z/.freeze
  CRAWL_ERROR = /\A<- Error on (.+?): (.+)\z/.freeze
  CRAWL_ALREADY = /\A<- Done with (\S+), already fetched\.\z/.freeze
  CRAWL_DEPTH0 = /\A<- Done with (\S+), depth 0\.\z/.freeze
  CRAWL_DONE = /\A<- Done with (\S+)\z/.freeze

  def facts_webcrawler_crawl(lines, params, result)
    bodies = params.fetch('bodies')
    missing_urls = params.fetch('missing')
    known = bodies.keys + missing_urls
    links = params.fetch('links')
    expected_edges = links.flat_map do |parent, targets|
      targets.each_with_index.map { |child, i| [parent, i.to_s, targets.length.to_s, child] }
    end
    already_urls = Hash.new(0)
    found_at, done_at, wait_at = {}, {}, {}
    header = params.fetch('stats_header')
    index = lines.each_index.select { |i| lines[i] == header[0] }
    unless index.length == 1 && lines[index[0] + 1] == header[1]
      result['findings'] << "stats_header:#{index.length}"
      return
    end
    crawl = lines[0...index[0]]
    stats = lines[(index[0] + 2)..] || []

    # -- the statistics block is fully determined: exact set, no repeats.
    expected_stats = bodies.keys.map { |url| "#{url} was fetched" } +
                     missing_urls.map { |url| "#{url} failed: not found: #{url}" }
    stats_counts = Hash.new(0)
    stats.each { |line| stats_counts[line] += 1 }
    duplicated = stats_counts.select { |_, n| n > 1 }.keys.sort
    result['findings'] << "stats_duplicate:#{duplicated.inspect}" unless duplicated.empty?
    missing_stats = expected_stats - stats
    extra_stats = stats - expected_stats
    result['findings'] << "stats_missing:#{missing_stats.inspect}" unless missing_stats.empty?
    result['findings'] << "stats_unexpected:#{extra_stats.inspect}" unless extra_stats.empty?

    found = Hash.new(0)
    done = Hash.new(0)
    errors = Hash.new(0)
    already = 0
    depth0 = 0
    children = Hash.new(0)
    waits = Hash.new(0)
    child_at = {}
    crawl.each_with_index do |line, i|
      case line
      when CRAWL_FOUND
        url, body = Regexp.last_match(1), Regexp.last_match(2)
        found[url] += 1
        found_at[url] ||= i
        result['findings'] << "unknown_url:#{url}" unless known.include?(url)
        result['findings'] << "found_body:#{url}:#{body.inspect}" unless bodies[url] == body
      when CRAWL_CHILD
        key = [Regexp.last_match(3), Regexp.last_match(1), Regexp.last_match(2), Regexp.last_match(4)]
        children[key] += 1
        child_at[key] ||= i
        result['findings'] << "unknown_url:#{key[3]}" unless known.include?(key[3])
      when CRAWL_WAIT
        key = [Regexp.last_match(1), Regexp.last_match(2), Regexp.last_match(3), Regexp.last_match(4)]
        waits[key] += 1
        wait_at[key] ||= i
        at = child_at[key]
        result['findings'] << "causal_order:wait_before_crawl:#{key.inspect}" if at.nil? || at > i
      when CRAWL_ALREADY
        url = Regexp.last_match(1)
        already += 1
        already_urls[url] += 1
        result['findings'] << "unknown_url:#{url}" unless known.include?(url)
      when CRAWL_DEPTH0
        depth0 += 1
        result['findings'] << 'unexpected_depth_zero' # This pinned graph first visits every body at depth >= 2.
      when CRAWL_ERROR
        url, message = Regexp.last_match(1), Regexp.last_match(2)
        errors[url] += 1
        result['findings'] << "unexpected_error_url:#{url}" unless missing_urls.include?(url)
        result['findings'] << "error_message:#{url}:#{message.inspect}" unless message == "not found: #{url}"
      when CRAWL_DONE
        url = Regexp.last_match(1)
        done[url] += 1
        done_at[url] ||= i
        result['findings'] << "unknown_done_url:#{url}" unless bodies.key?(url)
      else
        result['findings'] << "unparsed_line:#{i}:#{line.inspect}"
      end
    end

    bodies.each_key do |url|
      result['findings'] << "found_multiplicity:#{url}:#{found[url]}!=1" unless found[url] == 1
      result['findings'] << "done_multiplicity:#{url}:#{done[url]}!=1" unless done[url] == 1
    end
    missing_urls.each do |url|
      result['findings'] << "error_multiplicity:#{url}:#{errors[url]}!=1" unless errors[url] == 1
      result['findings'] << "found_unfetchable:#{url}" if found[url].positive?
    end
    unpaired = (children.keys | waits.keys).reject { |key| children[key] == 1 && waits[key] == 1 }
    result['findings'] << "child_wait_pairing:#{unpaired.sort.inspect}" unless unpaired.empty?
    result['findings'] << 'crawl_topology' unless children.keys.sort == expected_edges.sort
    expected_edges.each do |key|
      parent = key[0]
      if child_at[key] && (!found_at[parent] || child_at[key] < found_at[parent])
        result['findings'] << "causal_order:crawl_before_parent_found:#{key.inspect}"
      end
      if wait_at[key] && (!done_at[parent] || wait_at[key] > done_at[parent])
        result['findings'] << "causal_order:parent_done_before_wait:#{key.inspect}"
      end
    end
    known.each do |url|
      visits = expected_edges.count { |edge| edge[3] == url } + (url == params.fetch('root') ? 1 : 0)
      result['findings'] << "already_multiplicity:#{url}" unless already_urls[url] == visits - 1
    end
    result['already_fetched'] = already
    result['depth_exhausted'] = depth0
    result['edges'] = children.values.sum
    result['crawl_lines'] = crawl.length
  end

  def reconcile_webcrawler_crawl(candidate, oracle, _params, _window)
    range_finding('already_fetched', candidate['already_fetched'], oracle.map { |o| o['already_fetched'] }) +
      range_finding('depth_exhausted', candidate['depth_exhausted'], oracle.map { |o| o['depth_exhausted'] }) +
      range_finding('edges', candidate['edges'], oracle.map { |o| o['edges'] })
  end
end
