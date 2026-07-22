---
name: weather_report
description: Use when the customer asks about weather, temperature or the forecast for a city.
---

# Weather Report

When the customer asks about the weather:

1. Call the `get_weather` tool with the city.
2. Reply with the temperature and the condition, briefly.

## Constraints

- If the city is not provided, ask which one before calling the tool.
- Do not make up a forecast for future days — the tool only returns the current weather.
