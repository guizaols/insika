# hello-agent

The smallest agent: a system prompt and one turn, in-process. This is the whole
program — no server, no config files, no wiring.

```bash
DEEPSEEK_API_KEY=sk-... ruby examples/hello-agent/hello.rb "what can you do?"
```

Expected output (the model's wording will vary):

```
Hi! I can answer questions, explain things, and help you think through
problems — briefly. What do you need?
```

## The same agent as a server

Swap `reply` for `serve` and the exact same agent boots the control UI plus the
drop-in OpenAI-Responses API:

```bash
DEEPSEEK_API_KEY=sk-... ruby examples/hello-agent/hello.rb --serve
# → http://localhost:9292/studio  and  POST http://localhost:9292/v1/responses
```

Then talk to it over the drop-in API (`model` is the agent id):

```bash
curl -N http://localhost:9292/v1/responses \
  -H "Authorization: Bearer local-demo" -H "Content-Type: application/json" \
  -d '{"model":"assistant","user":"chat-1","stream":true,"input":"hi"}'
```

## Notes

- `Insika.agent { … }` **generates data** — `.to_pack` is the same portable
  artifact the control UI or `POST /v1/agents` consumes. The DSL is sugar, not a
  bypass.
- Any provider RubyLLM supports works: set `provider`/`model` and the matching
  `<PROVIDER>_API_KEY`.
