# frozen_string_literal: true

require "test_helper"

class TestTimeCollector < Minitest::Test
  SLOW_RUNNER = ENV["GITHUB_ACTIONS"] && ENV["RUNNER_OS"] == "macOS"
  DEFAULT_SLEEP_SCALE =
      if SLOW_RUNNER
        1
      else
        0.1
      end
  SLEEP_SCALE = ENV.fetch("TEST_SLEEP_SCALE", DEFAULT_SLEEP_SCALE).to_f # seconds/100ms
  SAMPLE_SCALE_INTERVAL = 10_000 * SLEEP_SCALE # Microseconds

  def slow_method
    sleep SLEEP_SCALE
  end

  def two_slow_methods
    slow_method
    1.times do
      slow_method
    end
  end

  def test_receives_gc_events
    collector = Vernier::Collector.new(:wall)
    collector.start
    GC.start
    GC.start
    result = collector.stop

    assert_valid_result result
    # make sure we got all GC events (since we did GC.start twice)
    assert_equal ["GC end marking", "GC end sweeping", "GC pause", "GC start"].sort,
      result.markers.map { |x| x[1] }.grep(/^GC/).uniq.sort
  end

  def test_time_collector
    collector = Vernier::Collector.new(:wall, interval: SAMPLE_SCALE_INTERVAL)
    collector.start
    two_slow_methods
    result = collector.stop

    assert_valid_result result
    assert_similar 200, result.weights.sum

    samples_by_stack = result.samples.zip(result.weights).group_by(&:first).transform_values do |samples|
      samples.map(&:last).sum
    end
    significant_stacks = samples_by_stack.select { |k,v| v > 10 }
    assert_equal 2, significant_stacks.size
    assert_similar 200, significant_stacks.sum(&:last)
  end

  def test_sleeping_threads
    collector = Vernier::Collector.new(:wall, interval: SAMPLE_SCALE_INTERVAL)
    th1 = Thread.new { two_slow_methods; Thread.current.object_id }
    th2 = Thread.new { two_slow_methods; Thread.current.object_id }
    collector.start
    th1id = th1.value
    th2id = th2.value
    result = collector.stop

    tally = result.threads.transform_values do |thread|
      # Number of samples
      thread[:weights].sum
    end.to_h

    assert_similar 200, tally[Thread.current.object_id]
    assert_similar 200, tally[th1id]
    assert_similar 200, tally[th2id]

    assert_valid_result result
    # TODO: some assertions on behaviour
  end

  def count_up_to(n)
    i = 0
    while i < n
      i += 1
    end
  end

  def test_two_busy_threads
    collector = Vernier::Collector.new(:wall)
    th1 = Thread.new { count_up_to(10_000_000) }
    th2 = Thread.new { count_up_to(10_000_000) }
    collector.start
    th1.join
    th2.join
    result = collector.stop

    assert_valid_result result
    # TODO: some assertions on behaviour
  end

  def test_many_threads
    50.times do
      collector = Vernier::Collector.new(:wall)
      collector.start
      50.times.map do
        Thread.new { count_up_to(2_000) }
      end.map(&:join)
      result = collector.stop
      assert_valid_result result
    end

    # TODO: some assertions on behaviour
  end

  def test_many_empty_threads
    50.times do
      collector = Vernier::Collector.new(:wall)
      collector.start
      50.times.map do
        Thread.new { }
      end.map(&:join)
      result = collector.stop
      assert_valid_result result
    end
  end

  def test_sequential_threads
    collector = Vernier::Collector.new(:wall)
    collector.start
    10.times do
      10.times.map do
        Thread.new { sleep 0.1 }
      end.map(&:join)
    end
    result = collector.stop
    assert_valid_result result
  end

  def test_killed_threads
    collector = Vernier::Collector.new(:wall)
    collector.start
    threads = 10.times.map do
      Thread.new { sleep 100 }
    end
    threads.shuffle!
    Thread.new do
      until threads.empty?
        sleep 0.01
        threads.shift.kill
      end
    end.join
    result = collector.stop
    assert_valid_result result
  end

  def test_nested_collections
    outer_result = inner_result = nil
    outer_result = Vernier.trace(interval: SAMPLE_SCALE_INTERVAL) do
      inner_result = Vernier.trace(interval: SAMPLE_SCALE_INTERVAL) do
        slow_method
      end
      slow_method
    end

    assert_similar 100, inner_result.weights.sum
    assert_similar 200, outer_result.weights.sum
  end

  ExpectedError = Class.new(StandardError)
  def test_raised_exceptions_will_output
    output_file = File.join(__dir__, "../tmp/exception_output.json")

    assert_raises(ExpectedError) do
      Vernier.trace(out: output_file) do
        raise ExpectedError
      end
    end

    assert File.exist?(output_file)
  end

  class ThreadWithInspect < ::Thread
    def inspect
      raise "boom!"
    end
  end

  def test_thread_with_inspect
    result = Vernier.trace do
      th1 = ThreadWithInspect.new { sleep 0.01 }
      th1.join
    end

    assert_valid_result result
  end

  def assert_similar expected, actual
    delta_ratio =
      if SLOW_RUNNER
        0.25
      else
        0.1
      end
    delta = expected * delta_ratio
    assert_in_delta expected, actual, delta
  end
end
