# frozen_string_literal: true

require "time"

module Harness
  module Telemetry
    # Traduz o Event Stream do harness em SPANS OTEL — a espinha de observabilidade
    # já existente vira traces sem tocar o núcleo (Events observam; Telemetry só
    # consome). Um span por TURNO (harness.turn) com spans-filho por tool
    # (harness.tool / harness.data_tool), correlacionados por task_id. Latência sai
    # da duração do span; tokens/custo e agente/modelo saem dos ATRIBUTOS — o
    # backend (SigNoz/Tempo/…) agrega em métricas. Sem depender do SDK de métricas.
    #
    # PURO/testável: fala com um `tracer` DUCK-TYPED (start_span/set_attribute/
    # record_error/finish) — o adapter OTEL real é injetado em Telemetry.setup, um
    # fake nos testes. NÃO referencia OpenTelemetry:: (carrega sem a gem).
    #
    # Robusto: `record` NUNCA levanta (telemetria não derruba turno). Timestamps
    # vêm do `meta.at` de cada evento (spans reconstruídos com tempo real).
    class Recorder
      Turn = Struct.new(:span, :tools) # tools = fila FIFO dos spans de tool abertos

      # Teto de turnos abertos: um kill -9 sem evento terminal deixaria o turno
      # pendurado; ao exceder, o mais antigo é fechado (defensivo, memória limitada).
      MAX_OPEN = 1_000

      def initialize(tracer:)
        @tracer = tracer
        @turns = {}
      end

      def record(event)
        meta = event.meta || {}
        data = event.data || {}
        case event.type
        when :task_started   then start_turn(meta, data)
        when :tool_call      then start_tool(meta, data)
        when :tool_result    then finish_tool(meta)
        when :data_tool_call then point_tool(meta, data)
        when :task_completed then finish_turn(meta, data, :ok)   # :done é o gêmeo legado — ignorado
        when :task_failed    then finish_turn(meta, data, :error)
        when :task_cancelled then finish_turn(meta, data, :cancelled)
        end
        nil
      rescue StandardError
        nil # telemetria NUNCA derruba o consumidor/turno
      end

      private

      def start_turn(meta, data)
        id = meta[:task_id] or return
        evict_oldest if @turns.size >= MAX_OPEN
        span = @tracer.start_span(
          "harness.turn", parent: nil, start_time: ts(meta[:at]),
          attributes: attrs("harness.task_id" => id, "harness.session_id" => meta[:session_id],
                            "harness.agent" => data[:agent], "harness.command" => data[:command]&.to_s)
        )
        @turns[id] = Turn.new(span, [])
      end

      def start_tool(meta, data)
        turn = @turns[meta[:task_id]] or return
        span = @tracer.start_span("harness.tool", parent: turn.span, start_time: ts(meta[:at]),
                                  attributes: attrs("harness.tool" => data[:name]&.to_s))
        turn.tools << span
      end

      # FIFO: o modelo chama uma tool e recebe o resultado antes da próxima, então
      # o resultado casa com o primeiro span de tool aberto do turno.
      def finish_tool(meta)
        turn = @turns[meta[:task_id]] or return
        span = turn.tools.shift or return
        span.finish(end_time: ts(meta[:at]))
      end

      # data-tool emite um único evento (nome + status HTTP) -> span pontual.
      def point_tool(meta, data)
        turn = @turns[meta[:task_id]] or return
        at = ts(meta[:at])
        span = @tracer.start_span("harness.data_tool", parent: turn.span, start_time: at,
                                  attributes: attrs("harness.tool" => data[:tool]&.to_s,
                                                    "harness.http.status" => data[:status]))
        span.finish(end_time: at)
      end

      def finish_turn(meta, data, status)
        turn = @turns.delete(meta[:task_id]) or return
        at = ts(meta[:at])
        set_usage(turn.span, data[:usage])
        turn.span.set_attribute("harness.status", status.to_s)
        turn.span.record_error(data[:message].to_s) if status == :error
        turn.tools.each { |s| s.finish(end_time: at) } # spans de tool órfãos (falha no meio)
        turn.span.finish(end_time: at)
      end

      def set_usage(span, usage)
        return unless usage

        span.set_attribute("harness.tokens.input", usage[:input_tokens]) if usage[:input_tokens]
        span.set_attribute("harness.tokens.output", usage[:output_tokens]) if usage[:output_tokens]
        span.set_attribute("harness.tokens.total", usage[:total_tokens]) if usage[:total_tokens]
        span.set_attribute("harness.tokens.cached", usage[:cached_tokens]) if usage[:cached_tokens]
        span.set_attribute("harness.model", usage[:model].to_s) if usage[:model]
      end

      def evict_oldest
        _id, turn = @turns.shift
        return unless turn

        turn.tools.each { |s| s.finish(end_time: nil) }
        turn.span.set_attribute("harness.status", "abandoned")
        turn.span.finish(end_time: nil)
      end

      # OTEL não aceita atributo com valor nil — descarta as chaves ausentes.
      def attrs(hash) = hash.reject { |_, v| v.nil? }

      # ISO8601 (meta.at) -> Time; nil-safe (o span usa "agora" quando nil).
      def ts(at)
        return nil if at.nil? || at.to_s.empty?

        Time.parse(at.to_s)
      rescue ArgumentError
        nil
      end
    end
  end
end
