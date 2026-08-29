---
title: Media
parent: Integrate
nav_order: 3
permalink: /media/
---

# Media

The engine transports media, it never means it. Photos, voice notes and documents
travel through the message contract as additive content parts; what a picture
*means* — a fitting room, a product mockup — stays a skill on top.

## In — the message contract

The engine transports media, it never means it. The message accepts additive
**content parts** alongside the text — voice notes and photos travel, and any
skill (a fitting room, an image QA) stays a consumer layer on top:

```bash
curl -X POST /v1/messages?stream=false -H "Authorization: Bearer $TOKEN" \
  -d '{ "agent": "store-support", "session_id": "chat-7",
        "message": "", "parts": [
          { "type": "audio", "url": "https://cdn.example.com/voz.ogg" },
          { "type": "image", "url": "https://cdn.example.com/sofa.jpg" },
          { "type": "document", "url": "https://cdn.example.com/receita.pdf" }
        ] }'
```

- **Audio** is transcribed (RubyLLM STT; model via `INSIKA_STT_MODEL`) and the
  text enters the turn marked `source: "voice"` on the terminal event — the
  consumer's signal the person spoke. A consumer that transcribes itself can
  send the text with `"source": "voice"` directly. A domain vocabulary hint
  (product names, brand terms) rides the transcription as `prompt:` —
  per-agent `stt_prompt` (the DSL setter, or the Studio config form) beats the
  deployment-wide `INSIKA_STT_PROMPT` env, which beats nothing. OPERATOR
  config, never customer input.
- **Images** attach to the model's ask (vision); the provider bills them and
  the usage flows like any ask. The first image URL is also
  `{{ctx.image_url}}` for data tools — photo analysis outside the prompt, the
  tool's own egress applying when it fetches.
- **Documents** (a prescription, a recipe, an invoice — most often a PDF)
  attach the same way images do; the first document URL is
  `{{ctx.document_url}}`. A model without document support fails the ask at
  `:ruby_llm` with the provider's own error — the transport does not preflight
  capability. Capped at 10 MB (`MAX_DOCUMENT_BYTES` — "a prescription, not an
  archive"), separately from the 5 MB image cap.
- Media URLs (audio, image AND document) are fetched by the engine through
  the same egress guard (a private/metadata target is refused — SSRF) and a
  size ceiling per kind (1 MB audio, 5 MB image, 10 MB document: the bytes
  land in this process). A refused, oversized or unreadable part fails the turn
  loudly at the `:media` stage, never a silent drop.
- **Media alone is a turn.** A voice note with no caption is `parts` and an
  empty `message` — the transcription becomes the message at the `:media`
  stage. A media message never joins another turn (`collect`/`steer` move text
  only, and the parts would be left behind), and a transcription that comes
  back empty fails the turn instead of asking the model about nothing.
- **Parts are contract at the edge** — a malformed part (unknown type, an
  image/audio/document without `url`, a text without `text`) is a 422 before
  dispatch on `/v1/messages` and `/v1/responses`. `document` is an ADDITIVE
  part type (the compatibility rule in [the /v1 API](API.md) — no
  `Insika-Version` bump needed).
- `/v1/responses` accepts the OpenAI multimodal shape: `input` as an array of
  text/image/audio/document parts.

### Image editing

`generate_image` (below) doesn't only generate — it can EDIT an existing
image, using `RubyLLM.paint`'s `with:`/`mask:`. The tool exposes
`source_image_urls` (an array — up to 4) and `mask_url`; when the model omits
`source_image_urls` AND the turn carries an inbound photo, that photo is
edited by default — no URL round-trip needed for "edit the photo the customer
just sent". Explicit URLs always win over the default. A text-to-image call
(no sources at all) is byte-identical to before this feature existed.

What the edit MEANS — a virtual try-on, a product mockup on the customer's
wall — is the calling skill's business; the tool only transports the bytes.
Not every image model can edit (`dall-e-3` cannot); a call against a
non-editing model fails at the provider, surfaced verbatim.

## Out — generated media

The turn can **produce** an image or a voice clip — but only when both sides of
the gate agree, because nothing leaks by default. The agent declares it may
generate media (`outputs` on the profile), and the **channel** declares it can
receive it (`channel.capabilities` on the request):

```bash
curl -X POST /v1/responses -H "Authorization: Bearer $TOKEN" -d '{
  "model": "openclaw:store-support", "user": "chat-7",
  "input": "manda a foto do sofá da promoção",
  "channel": { "capabilities": ["image_output", "audio_output"] }
}'
```

```ruby
agent = Insika.agent("store-support") do
  instructions "…"
  outputs image: { model: "gpt-image-1", size: "1024x1024" },   # the AGENT's half
          tts:   { model: "tts-1", voice: "alloy" }
end
```

- **Both gates** must pass for the model to even see the `generate_image` /
  `tts` tools: the agent opted in (`outputs`) and the request declared the
  matching capability (`image_output` / `audio_output` — an unknown value is a
  422, never a silent ignore). The "abstraction admits only what leaks" rule.
- **The media rides the envelope, never the answer text.** The terminal event
  and the `/v1/responses` completed frame carry an additive `output_parts`
  array — `{ type: "image", mime_type:, base64:, model: }` /
  `{ type: "audio", mime_type:, base64:, model: }`. The model's prose stays
  the `:content` answer; the channel consumes the bytes next to it.
- **Generation is billed and counted.** Image tokens join the turn's usage
  (like any ask). The speech API reports no token counts, so a TTS call adds
  an honest `usage.media` counter and the part carries the `model` for
  consumer-side pricing.
- **Seams, not magic.** The generator is injectable per kind (specs stub it);
  the defaults are lazy: images via RubyLLM (paint), speech via a thin POST to
  the OpenAI-compatible `/audio/speech` endpoint using the same provider
  config the chat uses — RubyLLM as of 1.16.0 has no speech API. A generated
  part over 8 MB refuses loudly, never silently truncates.
- **Not here:** what the generated image *means* — a fitting room, a product
  mockup — is a skill on top. The engine transports bytes and cost.

## See also

- [The /v1 API](API.md) — the full message contract.
- [Channels](CHANNELS.md) — how WhatsApp and the web widget carry these parts.
