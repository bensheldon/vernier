# frozen_string_literal: true

require_relative "marker"

module Vernier
  class Collector
    def initialize(mode, options={})
      @mode = mode
      @markers = []
      @hooks = []

      if options[:hooks]
        Array(options[:hooks]).each do |hook|
          add_hook(hook)
        end
      end
      @hooks.each do |hook|
        hook.enable
      end
    end

    private def add_hook(hook)
      case hook
      when :rails, :activesupport
        @hooks << Vernier::Hooks::ActiveSupport.new(self)
      else
        warn "Unknown hook: #{hook}"
      end
    end

    ##
    # Get the current time.
    #
    # This method returns the current time from Process.clock_gettime in
    # integer nanoseconds.  It's the same time used by Vernier internals and
    # can be used to generate timestamps for custom markers.
    def current_time
      Process.clock_gettime(Process::CLOCK_MONOTONIC, :nanosecond)
    end

    def add_marker(name:, start:, finish:, thread: Thread.current.object_id, phase: Marker::Phase::INTERVAL, data: nil)
      @markers << [thread,
                   name,
                   start,
                   finish,
                   phase,
                   data]
    end

    ##
    # Record an interval with a category and name.  Yields to a block and
    # records the amount of time spent in the block as an interval marker.
    def record_interval(category, name = category)
      start = current_time
      yield
      add_marker(
        name: category,
        start:,
        finish: current_time,
        phase: Marker::Phase::INTERVAL,
        thread: Thread.current.object_id,
        data: { :type => 'UserTiming', :entryType => 'measure', :name => name }
      )
    end

    def stop
      result = finish

      result.hooks = @hooks

      end_time = Process.clock_gettime(Process::CLOCK_REALTIME, :nanosecond)
      result.pid = Process.pid
      result.end_time = end_time

      marker_strings = Marker.name_table

      markers = self.markers.map do |(tid, type, phase, ts, te, stack)|
        name = marker_strings[type]
        sym = Marker::MARKER_SYMBOLS[type]
        data = { type: sym }
        data[:cause] = { stack: stack } if stack
        [tid, name, ts, te, phase, data]
      end

      markers.concat @markers

      result.instance_variable_set(:@markers, markers)

      result
    end
  end
end
