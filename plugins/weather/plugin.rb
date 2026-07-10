# frozen_string_literal: true

require "ruby_llm"

# Plugin de exemplo. O módulo responde a .register(api) — o análogo Ruby do
# register(api) { api.registerTool(...) } do OpenClaw.
module WeatherPlugin
  class GetWeather < RubyLLM::Tool
    description "Consulta o clima atual de uma cidade"
    param :city, desc: "Nome da cidade"

    def execute(city:)
      # STUB — plugue uma API real de clima aqui.
      { city: city, temp_c: 24, condition: "ensolarado" }
    end
  end

  def self.register(api)
    api.register_tool("get_weather", GetWeather)
  end
end
