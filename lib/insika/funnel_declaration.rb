# frozen_string_literal: true

module Insika
  # the parsed funnel declaration of ONE agent — the ONLY shape
  # the engine accepts, shared by the fold, the doctor, the Studio and the
  # freeze command. Pure value object: it never touches a store, and the engine
  # never hard-codes a stage name (D1) — `stages`/`primary`/`advance_on` are the
  # forge's vocabulary, carried as data.
  #
  # `parse` returns nil on a malformed hash (D8: the fold skips that agent, the
  # doctor explains the exact defect); `parse!` raises Insika::ValidationError
  # naming the field. `attribution_window` is carried data, never computed (D4).
  class FunnelDeclaration
    WINDOW_RE = /\A\d+h\z/

    attr_reader :stages, :advance_on, :primary, :attribution_window

    def self.parse(hash)
      new(hash)
    rescue Insika::ValidationError
      nil
    end

    def self.parse!(hash)
      new(hash)
    end

    def initialize(hash)
      raise Insika::ValidationError, "funnel: declaration must be a Hash" unless hash.is_a?(Hash)

      h = hash.transform_keys(&:to_s)
      @stages = stages_of(h)
      @advance_on = advance_on_of(h, @stages)
      @primary = primary_of(h, @stages)
      @attribution_window = window_of(h)
      freeze
    end

    # position of a stage in the declared order. -> Integer | nil
    def index_of(stage)
      index = @stages.index(stage.to_s)
      index.nil? ? nil : index
    end

    # the first declared stage — the funnel's denominator.
    def first_stage = @stages.first

    # "72h" -> 72 (Integer). Always valid once parsed.
    def window_hours = @attribution_window.to_i

    # Value-object equality: two declarations parsed from equal input (symbol
    # or string keys) are the same declaration.
    def ==(other)
      other.is_a?(FunnelDeclaration) &&
        @stages == other.stages && @advance_on == other.advance_on &&
        @primary == other.primary && @attribution_window == other.attribution_window
    end
    alias eql? ==

    def hash
      [@stages, @advance_on, @primary, @attribution_window].hash
    end

    private

    def stages_of(hash)
      list = hash["stages"]
      raise Insika::ValidationError, "funnel.stages: must be a non-empty Array of non-blank Strings" unless valid_stages?(list)

      list
    end

    def valid_stages?(list)
      list.is_a?(Array) && !list.empty? && list.all? { |s| s.is_a?(String) && !s.strip.empty? } &&
        list.uniq.length == list.length
    end

    def advance_on_of(hash, stages)
      map = hash["advance_on"]
      raise Insika::ValidationError, "funnel.advance_on: must be a non-empty Hash of kind => stage" unless map.is_a?(Hash) && !map.empty?

      map = map.transform_keys(&:to_s)
      unless map.all? { |kind, stage| !kind.strip.empty? && stage.is_a?(String) && stages.include?(stage) }
        raise Insika::ValidationError, "funnel.advance_on: every value must be one of the declared stages"
      end

      map
    end

    def primary_of(hash, stages)
      primary = hash["primary"]
      raise Insika::ValidationError, "funnel.primary: must be one of the declared stages" unless primary.is_a?(String) && stages.include?(primary)

      primary
    end

    def window_of(hash)
      window = hash["attribution_window"]
      unless window.is_a?(String) && WINDOW_RE.match?(window)
        raise Insika::ValidationError, "funnel.attribution_window: must match /\\A\\d+h\\z/ (e.g. \"72h\")"
      end

      window
    end
  end
end
