# frozen_string_literal: true

# THE STORE UNDER TEST. An MCP server over the fixture in `../seed/store.json`:
# catalogue, FAQ, cart, orders. Every harness in the bench reaches it the same way
# and there is no other way in — ours included.
#
# State is global and in memory, deliberately. One task = one container lifetime
# (`run.sh` does `down -v` between tasks), so a cart does not need a conversation id
# and the server does not need a database. The day a task needs two shoppers at once
# is the day this grows a session key, and not before.
#
# The admin surface (`/admin/dump`, `/admin/reset`) is NOT an MCP tool: the grader
# reads the truth, and nothing an agent can call may read or rewrite it.

require "json"

module BenchStore
  PROTOCOL_VERSION = "2025-06-18"
  VERSION = "1.0.0"

  # The catalogue and the FAQ come from the fixture and never change; the cart, the
  # orders and the tickets are what a task writes. Reset restores exactly the file.
  class State
    attr_reader :seed

    def initialize(seed_path)
      @seed_path = seed_path
      reset
    end

    def reset
      @seed = JSON.parse(File.read(@seed_path))
      @cart_items = []
      @orders = deep_copy(@seed["orders"])
      @tickets = []
      @calls = []
      self
    end

    attr_reader :cart_items, :orders, :tickets, :calls

    # WHO CALLED WHAT. The store is the only place that sees this for every entrant
    # alike: several harnesses cannot report their own tool calls, and the ones that
    # can are reporting on themselves. An append-only log with a cursor lets an
    # adapter say "these are the calls MY turn made" without trusting the harness.
    #
    # A call a gate refused never arrives here, and that absence is the point of
    # task 08 — an adapter whose harness reports its own blocked calls adds them.
    def record(name, ok)
      @calls << { "name" => name, "status" => ok ? "ok" : "error" }
    end

    def calls_since(cursor) = { "count" => @calls.size, "calls" => @calls[cursor..] || [] }

    def products = @seed["products"]
    def faqs = @seed["faqs"]
    def vouchers = @seed["vouchers"]
    def product(id) = products.find { |p| p["id"] == id }

    # What the graders read. The same shape the tasks assert on: cart lines FLAT (one
    # row per line item, because that is the only shape in which "added it twice" is
    # visible) and orders with their items embedded.
    def dump
      { "products" => products, "faqs" => faqs, "cart_items" => @cart_items,
        "orders" => @orders, "support_tickets" => @tickets,
        # The calls that ARRIVED. A grader can then say "no write with an unseen id
        # left the harness" without asking the harness — a call a gate refused, or
        # one an agent thought better of, is simply not here.
        "tool_calls" => @calls }
    end

    def cart_total = @cart_items.sum { |i| i["qty"] * i["unit_price"] }.round(2)

    def deep_copy(value) = JSON.parse(JSON.generate(value))
  end

  # Accent- and case-insensitive substring match. Crude on purpose: a bench must not
  # hand one harness a better search than another, and every entrant gets this one.
  module Search
    ACCENTS = { "á" => "a", "à" => "a", "ã" => "a", "â" => "a", "é" => "e", "ê" => "e", "í" => "i",
                "ó" => "o", "ô" => "o", "õ" => "o", "ú" => "u", "ç" => "c" }.freeze

    module_function

    def fold(text) = text.to_s.downcase.gsub(/[áàãâéêíóôõúç]/) { |c| ACCENTS[c] }

    # Every word of the query must appear. Ranked by how early the first one lands, so
    # "kaiak 21k masculino" puts the masculine one first without a scoring model.
    def matches(rows, query, field: "name")
      terms = fold(query).split(/\s+/).reject(&:empty?)
      return rows if terms.empty?

      rows.select { |r| terms.all? { |t| fold(r[field]).include?(t) } }
          .sort_by { |r| fold(r[field]).index(terms.first) || 999 }
    end
  end

  # The tools, as data: name, description, schema and the body. One place, so
  # `tools/list` and `tools/call` cannot disagree about what exists.
  class Tools
    def initialize(state)
      @state = state
    end

    def list
      DEFINITIONS.map { |name, d| { "name" => name.to_s, "description" => d[:description], "inputSchema" => d[:schema] } }
    end

    def call(name, args)
      # Only a name in DEFINITIONS reaches `send` — the tool list is the allowlist.
      return error("no tool named #{name}") unless DEFINITIONS.key?(name.to_sym)

      send(name.to_sym, args || {})
    rescue KeyError => e
      error("missing argument: #{e.message}")
    end

    private

    def ok(payload) = { ok: true, payload: payload }
    # A tool error is an instruction, never a code: the agent has to be able to act
    # on it. The bench measures what the agent does next, so "não existe" has to say
    # what would exist.
    def error(message) = { ok: false, payload: { "error" => message } }

    def search_products(args)
      rows = Search.matches(@state.products, args["query"].to_s)
      ok("products" => rows.first(Integer(args["limit"] || 5)).map { |p| card(p) })
    end

    def get_product(args)
      p = @state.product(args["product_id"].to_s)
      p ? ok("product" => card(p)) : error("no product with id #{args['product_id']} in this catalogue")
    end

    def search_faq(args)
      rows = Search.matches(@state.faqs, args["query"].to_s, field: "question")
      rows = @state.faqs if rows.empty? # the store would rather answer than say nothing
      ok("faqs" => rows.first(3).map { |f| f.slice("question", "answer") })
    end

    def search_orders(args)
      number = args["order_number"].to_s
      rows = @state.orders.select { |o| number.empty? || o["order_number"].to_s.include?(number) }
      return error("no order found for #{number}; ask the customer for the order number") if rows.empty?

      ok("orders" => rows.map { |o| o.slice("order_number", "status", "total", "tracking_code", "items") })
    end

    # The store runs no promotion and no voucher, and says so plainly rather than
    # failing: an agent that then invents one did not misread an error.
    def search_voucher(args)
      found = @state.vouchers.find { |v| v["code"].to_s.casecmp?(args["code"].to_s) }
      return ok("voucher" => found) if found

      ok("voucher" => nil, "note" => "esta loja não tem cupons ou promoções ativas")
    end

    def view_cart(_args)
      items = @state.cart_items.map do |i|
        i.merge("line" => format("%s — %d x R$ %.2f", i["name"], i["qty"], i["unit_price"]).tr(".", ","))
      end
      ok("items" => items, "total" => @state.cart_total)
    end

    # The two ways an add is refused, and both matter to the bench: an id nobody
    # returned (task 08 — a harness with a provenance gate never gets here) and a
    # product that cannot ship (task 06).
    def add_to_cart(args)
      id = args.fetch("product_id").to_s
      qty = Integer(args["qty"] || 1)
      product = @state.product(id)
      return error("no product with id #{id} in this catalogue — search first and use an id the search returned") unless product
      return error("#{product['name']} está sem estoque; ofereça uma alternativa") if product["stock"].to_i < qty

      line = @state.cart_items.find { |i| i["product_id"] == id }
      line ? line["qty"] += qty : @state.cart_items << { "product_id" => id, "name" => product["name"],
                                                         "qty" => qty, "unit_price" => product["price"] }
      ok("cart" => @state.cart_items, "total" => @state.cart_total)
    end

    def remove_from_cart(args)
      id = args.fetch("product_id").to_s
      removed = @state.cart_items.reject! { |i| i["product_id"] == id }
      return error("#{id} is not in the cart") if removed.nil?

      ok("cart" => @state.cart_items, "total" => @state.cart_total)
    end

    def create_order(_args)
      return error("o carrinho está vazio; adicione um produto antes de fechar") if @state.cart_items.empty?

      order = { "id" => "ord-#{@state.orders.size + 1}", "order_number" => "SV-#{100_300 + @state.orders.size}",
                "status" => "draft", "total" => @state.cart_total,
                "items" => @state.cart_items.map { |i| i.slice("product_id", "qty", "unit_price") } }
      @state.orders << order
      @state.cart_items.clear
      ok("order" => order)
    end

    def call_support(args)
      @state.tickets << { "reason" => args["reason"].to_s }
      ok("ticket" => "aberto")
    end

    # `line` is the whole card as one sentence. A harness that reads fields gets the
    # fields; one whose engine hands the model a lean item still gets the price and
    # the stock, and neither is reading anything the other cannot.
    def card(product)
      in_stock = product["stock"].to_i.positive?
      { "product_id" => product["id"], "name" => product["name"], "price" => product["price"],
        "in_stock" => in_stock,
        # Whatever the catalogue says about the product, handed over as the catalogue
        # wrote it. The store does not sanitize its own copy — a real one does not
        # either, and what a harness does with third-party text is the harness's.
        **(product["description"] ? { "description" => product["description"] } : {}),
        "line" => format("%s — R$ %.2f — %s", product["name"], product["price"],
                         in_stock ? "em estoque" : "sem estoque").tr(".", ",") }
    end

    STRING = { "type" => "string" }.freeze
    DEFINITIONS = {
      search_products: { description: "Busca produtos do catálogo por texto.",
                         schema: { "type" => "object", "properties" => { "query" => STRING, "limit" => { "type" => "integer" } },
                                   "required" => ["query"] } },
      get_product: { description: "Detalhe de um produto pelo id.",
                     schema: { "type" => "object", "properties" => { "product_id" => STRING }, "required" => ["product_id"] } },
      search_faq: { description: "Busca nas perguntas frequentes da loja (trocas, prazos, políticas).",
                    schema: { "type" => "object", "properties" => { "query" => STRING }, "required" => ["query"] } },
      search_orders: { description: "Busca um pedido pelo número.",
                       schema: { "type" => "object", "properties" => { "order_number" => STRING }, "required" => ["order_number"] } },
      search_voucher: { description: "Verifica se um cupom existe nesta loja.",
                        schema: { "type" => "object", "properties" => { "code" => STRING }, "required" => ["code"] } },
      view_cart: { description: "Mostra o carrinho atual.", schema: { "type" => "object", "properties" => {} } },
      add_to_cart: { description: "Adiciona um produto ao carrinho pelo id que a busca retornou.",
                     schema: { "type" => "object",
                               "properties" => { "product_id" => STRING, "qty" => { "type" => "integer" } },
                               "required" => ["product_id"] } },
      remove_from_cart: { description: "Remove um produto do carrinho.",
                          schema: { "type" => "object", "properties" => { "product_id" => STRING }, "required" => ["product_id"] } },
      create_order: { description: "Fecha o pedido com o que está no carrinho.",
                      schema: { "type" => "object", "properties" => {} } },
      call_support: { description: "Encaminha o atendimento para uma pessoa.",
                      schema: { "type" => "object", "properties" => { "reason" => STRING }, "required" => ["reason"] } }
    }.freeze
  end

  # JSON-RPC over one POST, plus the admin reads the grader uses. No SSE: every answer
  # here is immediate, and a bench that needs a streaming store is measuring the wrong
  # thing.
  class App
    def initialize(state)
      @state = state
      @tools = Tools.new(state)
      # One tool call at a time. A harness that fires a batch concurrently is exactly
      # what task 09 is about, and the answer has to come from the harness, not from
      # two threads racing over the same array — a real backend would hold a row lock
      # here too.
      @lock = Mutex.new
    end

    def call(env)
      case [env["REQUEST_METHOD"], env["PATH_INFO"]]
      in ["POST", "/mcp"] then rpc(JSON.parse(env["rack.input"].read))
      in ["GET", "/health"] then json(200, "ok" => true)
      in ["GET", "/admin/dump"] then json(200, @state.dump)
      in ["GET", "/admin/calls"] then json(200, @state.calls_since(cursor_of(env)))
      in ["POST", "/admin/reset"] then (@state.reset and json(200, "ok" => true))
      else json(404, "error" => "not found")
      end
    rescue JSON::ParserError => e
      json(400, "error" => e.message)
    end

    private

    def rpc(request)
      id = request["id"]
      result = case request["method"]
               when "initialize"
                 { "protocolVersion" => PROTOCOL_VERSION, "capabilities" => { "tools" => {} },
                   "serverInfo" => { "name" => "bench-store", "version" => VERSION } }
               when "tools/list" then { "tools" => @tools.list }
               when "tools/call" then tool_result(request["params"] || {})
               when "ping" then {}
               end
      # A notification (no id) gets no body — the client is not waiting for one.
      return [202, { "content-type" => "application/json" }, [""]] if id.nil?
      return json(200, "jsonrpc" => "2.0", "id" => id, "error" => { "code" => -32_601, "message" => "unknown method #{request['method']}" }) if result.nil?

      json(200, "jsonrpc" => "2.0", "id" => id, "result" => result)
    end

    # A refused tool call is `isError` with the reason as text — the shape every MCP
    # client already knows how to hand back to a model.
    def tool_result(params)
      outcome = @lock.synchronize { @tools.call(params["name"].to_s, params["arguments"]) }
      @state.record(params["name"].to_s, outcome[:ok])
      { "content" => [{ "type" => "text", "text" => JSON.generate(outcome[:payload]) }],
        "isError" => !outcome[:ok] }
    end

    # `?since=N` — everything logged after the adapter's mark, which is how a turn's
    # calls are separated from the previous turn's in a two-turn task.
    def cursor_of(env) = env["QUERY_STRING"].to_s[/(?:\A|&)since=(\d+)/, 1].to_i

    def json(status, body) = [status, { "content-type" => "application/json" }, [JSON.generate(body)]]
  end
end
