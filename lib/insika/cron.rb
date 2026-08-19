# frozen_string_literal: true

module Insika
  # A cron expression, parsed. The engine's documented subset:
  #
  #   minute hour day-of-month month day-of-week     (5 fields, whitespace-separated)
  #
  # Per field: `*`, a single value, a range (N-M), a step (`*/N`, `N-M/N`,
  # `N/N`), or a comma list of those. `?` and `*` both mean "any". `L`, `W`,
  # `#` and month/day NAMES are NOT — the engine refuses them loudly at
  # creation, never silently dropping a cron that only some dates understand.
  #
  # Day-of-week: 0-7, 7 == 0 (Sunday). When BOTH day fields are restricted, a
  # date matches on EITHER (standard cron OR semantics).
  #
  # `next_after(time)` returns the first occurrence STRICTLY after `time`,
  # materialized in the schedule's tz (returned as a UTC Time), or nil when
  # the expression can never fire within 400 years (`0 0 31 2 *`). The bound
  # keeps a syntactic-but-unreachable expression from hanging a pass.
  class Cron
    MONTHS_31 = [1, 3, 5, 7, 8, 10, 12].freeze

    # One field: the sorted accepted values + whether it was a bare "*"
    # (the day-of-week OR rule needs to know which fields are restricted).
    class Field
      def initialize(expression, range, field:)
        @field = field
        @range = range
        @star = expression == "*"
        @values = expression.split(",").flat_map { |term| parse_term(term) }.uniq.sort
      end

      def star? = @star

      def matches?(value) = @values.include?(value)

      # -> Integer | nil: the smallest accepted value >= start (nil when none).
      def at_or_after(start) = @values.find { |v| v >= start }

      private

      def parse_term(term)
        head, step = term.include?("/") ? term.split("/", 2) : [term, nil]
        step = parse_step(step) if step
        base = parse_base(head)
        base = base.each_with_index.filter_map { |v, i| v if (i % step).zero? } if step
        base.each { |v| validate(v) }
      end

      def parse_step(raw)
        n = Integer(raw)
        raise Insika::ValidationError, "cron #{@field} step must be a positive integer, got #{raw.inspect}" unless n.positive?

        n
      rescue ArgumentError
        raise Insika::ValidationError,
              "cron #{@field} step must be a positive integer, got #{raw.inspect}"
      end

      def parse_base(head)
        if head.empty? || head == "?" || head == "*"
          @range.to_a
        elsif head.include?("-")
          lo, hi = head.split("-", 2).map { |s| value(s) }
          raise Insika::ValidationError, "cron #{@field} range reversed: #{head.inspect}" if lo > hi

          (lo..hi).to_a
        else
          [value(head)]
        end
      end

      def value(raw)
        v = Integer(raw)
        v = 0 if @field == :dow && v == 7 # Sunday, the standard second spelling
        v
      rescue ArgumentError
        raise Insika::ValidationError,
              "cron #{@field} has an unparseable value: #{raw.inspect}"
      end

      def validate(v)
        return if @range.cover?(v)

        raise Insika::ValidationError,
              "cron #{@field} value #{v} out of range (#{@range.inspect})"
      end
    end

    attr_reader :expression

    def initialize(expression)
      @expression = expression.to_s.strip
      fields = @expression.split(/\s+/)
      if fields.size != 5
        raise Insika::ValidationError,
              "cron expression must have 5 fields (minute hour dom month dow), " \
              "got #{fields.size}: #{@expression.inspect}"
      end

      minute, hour, dom, month, dow = fields
      @minute = Field.new(minute, 0..59, field: :minute)
      @hour = Field.new(hour, 0..23, field: :hour)
      @dom = Field.new(dom, 1..31, field: :dom)
      @month = Field.new(month, 1..12, field: :month)
      @dow = Field.new(dow, 0..6, field: :dow)
      freeze
    end

    # -> Time (UTC) | nil: the first instant strictly after `time` whose
    # wall-clock in `tz` matches. nil = the expression cannot fire within 400y.
    def next_after(time, tz: "Etc/UTC")
      Timezone.in_zone(tz, time) do
        local = time.getlocal
        cur = Cursor.new(local.year, local.month, local.day, local.hour, local.min)
        advance_minute!(cur) # strictly after `time`
        limit = cur.y + 400
        while cur.y <= limit
          if @month.matches?(cur.mo) && day_match?(cur)
            if @hour.matches?(cur.h) && (mm = @minute.at_or_after(cur.mi))
              return Time.local(cur.y, cur.mo, cur.d, cur.h, mm)
            end

            nh = @hour.at_or_after(cur.h + 1)
            if nh && (mm = @minute.at_or_after(0))
              return Time.local(cur.y, cur.mo, cur.d, nh, mm)
            end
          end
          advance_day!(cur)
          cur.h = 0
          cur.mi = 0
        end
        nil
      end
    end

    private

    # A date matches when a restricted day-of-month OR day-of-week accepts it
    # (standard cron); a bare "*" on one side drops that side.
    def day_match?(cur)
      dom = @dom.matches?(cur.d)
      dow = @dow.matches?(Time.utc(cur.y, cur.mo, cur.d).wday)
      if @dom.star? && @dow.star?
        true
      elsif @dom.star?
        dow
      elsif @dow.star?
        dom
      else
        dom || dow
      end
    end

    Cursor = Struct.new(:y, :mo, :d, :h, :mi)

    def advance_minute!(cur)
      cur.mi += 1
      if cur.mi > 59
        cur.mi = 0
        cur.h += 1
        advance_day!(cur) if cur.h > 23
      end
    end

    def advance_day!(cur)
      cur.d += 1
      return if cur.d <= days_in_month(cur.y, cur.mo)

      cur.d = 1
      cur.mo += 1
      if cur.mo > 12
        cur.mo = 1
        cur.y += 1
      end
    end

    def days_in_month(y, mo)
      return 29 if mo == 2 && leap?(y)
      return 28 if mo == 2

      MONTHS_31.include?(mo) ? 31 : 30
    end

    def leap?(y)
      y % 4 == 0 && (y % 100 != 0 || y % 400 == 0)
    end
  end
end