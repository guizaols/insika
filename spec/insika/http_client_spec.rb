# frozen_string_literal: true

require "spec_helper"
require "json"
require "socket"

# The default data-tool HTTP client, exercised over a REAL loopback socket: the
# bug it guards against only exists at the byte boundary (Net::HTTP yields
# ASCII-8BIT chunks), so a fake client would prove nothing.
#
# A tool response with an accent or an emoji used to come out tagged BINARY,
# travel into the transcript/event and only blow up further downstream, in the
# SSE frame's `JSON.generate` — a warning under json 2.x, an exception from
# json 3.0.
RSpec.describe Insika::HttpClient do
  # Minimal HTTP/1.1 server on an ephemeral port. `chunks` are written raw, one
  # write per element, so a multi-byte character can be SPLIT across two socket
  # reads — exactly the case that byte-level accumulation has to survive.
  def with_server(chunks:, status: "200 OK", location: nil)
    server = TCPServer.new("127.0.0.1", 0)
    thread = Thread.new do
      socket = server.accept
      while (line = socket.gets) && !line.strip.empty?; end # request line + headers
      body = chunks.join.b
      socket.write("HTTP/1.1 #{status}\r\nContent-Type: application/json\r\n" \
                   "#{location ? "Location: #{location}\r\n" : ''}" \
                   "Content-Length: #{body.bytesize}\r\nConnection: close\r\n\r\n")
      chunks.each { |c| socket.write(c) }
      socket.close
    end
    yield "http://127.0.0.1:#{server.addr[1]}/"
  ensure
    thread&.kill
    server&.close
  end

  def get(url, **over) = described_class.new(**over).request(method: "GET", url: url)

  it "returns an accented body as valid UTF-8 (not BINARY)" do
    payload = JSON.generate(msg: "pedido não encontrado 🚀")

    result = with_server(chunks: [payload.b]) { |url| get(url) }

    expect(result[:status]).to eq(200)
    expect(result[:body].encoding).to eq(Encoding::UTF_8)
    expect(result[:body]).to be_valid_encoding
    expect(JSON.parse(result[:body])["msg"]).to eq("pedido não encontrado 🚀")
  end

  it "the body survives a multi-byte character split across two socket writes" do
    bytes = "ação 🚀".b
    head = bytes[0, 3] # cuts INSIDE the "ç" (and would be invalid on its own)

    result = with_server(chunks: [head, bytes[3..]]) { |url| get(url) }

    expect(result[:body]).to eq("ação 🚀")
    expect(result[:body]).to be_valid_encoding
  end

  it "the accented body is JSON-serializable without an encoding warning" do
    payload = JSON.generate(msg: "café")

    result = with_server(chunks: [payload.b]) { |url| get(url) }

    # The real regression: what reaches an SSE frame is `JSON.generate` over the
    # tool result. Under json 2.x a BINARY string only WARNS, so assert on the
    # warning too — from json 3.0 this same case raises.
    expect { JSON.generate(delta: result[:body]) }.not_to output.to_stderr
  end

  it "a body with invalid bytes is scrubbed instead of poisoning the turn" do
    result = with_server(chunks: ["ok \xC3(".b]) { |url| get(url) }

    expect(result[:body]).to be_valid_encoding
    expect(result[:body]).to start_with("ok ")
    expect { JSON.generate(body: result[:body]) }.not_to raise_error
  end

  # It deliberately does NOT follow the hop: the EgressGuard cleared the authored
  # URL, not the redirect's destination. The target is REPORTED so a data-tool
  # whose API moved fails with something actionable (DataDefinedTool turns this
  # into "HTTP 301: moved to <url>") instead of the empty body a 3xx carries.
  it "does not follow a redirect: returns the 3xx and its Location" do
    result = with_server(chunks: [""], status: "301 Moved Permanently",
                         location: "https://api.example.test/v2/latest") { |url| get(url) }

    expect(result[:status]).to eq(301)
    expect(result[:location]).to eq("https://api.example.test/v2/latest")
    expect(result[:body]).to eq("")
  end

  it "a 2xx response carries no location key" do
    result = with_server(chunks: ["{}"]) { |url| get(url) }

    expect(result).not_to have_key(:location)
  end

  it "caps the response size by bytes" do
    expect do
      with_server(chunks: ["x" * 100]) { |url| get(url, max_bytes: 10) }
    end.to raise_error(described_class::ResponseTooLarge)
  end
end
