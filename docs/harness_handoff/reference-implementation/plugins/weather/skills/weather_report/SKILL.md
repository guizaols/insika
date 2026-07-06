---
name: weather_report
description: Use quando o cliente pergunta sobre clima, temperatura ou previsão do tempo de uma cidade.
---

# Weather Report

Quando o cliente pergunta sobre o clima:

1. Chame a tool `get_weather` com a cidade.
2. Responda com a temperatura e a condição, de forma curta.

## Restrições

- Se a cidade não for informada, pergunte qual antes de chamar a tool.
- Não invente previsão de dias futuros — a tool só dá o clima atual.
