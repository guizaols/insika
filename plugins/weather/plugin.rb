# frozen_string_literal: true

require "ruby_llm"

# Example plugin. The module responds to .register(api) — the Ruby analogue of
# OpenClaw's register(api) { api.registerTool(...) }.
module WeatherPlugin
  class GetWeather < RubyLLM::Tool
    description "Looks up the current weather for a city"
    param :city, desc: "City name"

    def execute(city:)
      # STUB — plug in a real weather API here.
      { city: city, temp_c: 24, condition: "sunny" }
    end
  end

  def self.register(api)
    api.register_tool("get_weather", GetWeather)
  end
end
