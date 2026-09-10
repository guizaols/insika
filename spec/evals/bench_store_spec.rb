# frozen_string_literal: true

require "spec_helper"
require "json"
require_relative "../../evals/bench/store/server"

# The store the whole table is measured against. If it is wrong, every row is wrong
# in the same direction and nobody can tell — so its contract with the tasks is
# pinned here: the ids they name, the refusals they expect, the collections they read.
RSpec.describe BenchStore do
  let(:seed_path) { File.expand_path("../../evals/bench/seed/store.json", __dir__) }
  let(:state) { BenchStore::State.new(seed_path) }
  let(:tools) { BenchStore::Tools.new(state) }
  let(:app) { BenchStore::App.new(state) }

  ANTIATRITO = "49599f78-7ba8-58ba-b9d8-3dfdfa7cfd1e" # R$ 49,90, in stock
  SABONETE = "a03ad0d9-b083-57cd-98a4-4d718e6b2fdd" # R$ 34,90, in stock
  BATOM = "c4e75a13-6ad6-5035-be9c-e52ec067afdb"    # out of stock, really
  MASC = "51307936-b478-59a2-a0ce-25c3d04f21d5"

  def call(name, args = {}) = tools.call(name, args)
  def payload(name, args = {}) = call(name, args)[:payload]

  describe "the surface" do
    it "offers exactly the ten tools the tasks use, and nothing that reads the truth" do
      names = tools.list.map { |t| t["name"] }
      expect(names).to contain_exactly("search_products", "get_product", "search_faq", "search_orders",
                                       "search_voucher", "view_cart", "add_to_cart", "remove_from_cart",
                                       "create_order", "call_support")
      expect(names.grep(/dump|admin|reset/)).to be_empty
    end

    it "answers an MCP initialize and lists its tools over JSON-RPC" do
      status, _, body = post("/mcp", "jsonrpc" => "2.0", "id" => 1, "method" => "initialize")
      expect(status).to eq(200)
      expect(JSON.parse(body.first).dig("result", "capabilities")).to have_key("tools")

      _, _, listed = post("/mcp", "jsonrpc" => "2.0", "id" => 2, "method" => "tools/list")
      expect(JSON.parse(listed.first).dig("result", "tools").size).to eq(10)
    end

    it "a notification gets no body, and an unknown method is an error, not a crash" do
      status, = post("/mcp", "jsonrpc" => "2.0", "method" => "notifications/initialized")
      expect(status).to eq(202)

      _, _, body = post("/mcp", "jsonrpc" => "2.0", "id" => 9, "method" => "tools/wat")
      expect(JSON.parse(body.first)).to have_key("error")
    end
  end

  describe "search" do
    it "ranks the named half of a confusable pair first" do
      first = payload("search_products", "query" => "colônia vento masculino")["products"].first
      expect(first["product_id"]).to eq(MASC)
    end

    it "reports stock as part of the card, so a harness cannot claim it did not know" do
      card = payload("search_products", "query" => "batom cremoso")["products"].first
      expect(card).to include("in_stock" => false, "price" => 23.9)
    end

    # Returned, not ranked first: three exchange FAQs match "troca" and the store
    # hands over all three. Which one the harness reads is the harness's business,
    # and every entrant gets the same three.
    it "surfaces the store's own exchange policy among the FAQs it returns" do
      faqs = payload("search_faq", "query" => "troca")["faqs"]
      expect(faqs.map { |f| f["answer"] }.join).to include("7 dias")
    end

    it "says plainly that there is no voucher, rather than failing" do
      out = call("search_voucher", "code" => "INFLUENCER20")
      expect(out[:ok]).to be(true)
      expect(out[:payload]["voucher"]).to be_nil
    end

    it "finds the seeded order with its tracking code" do
      order = payload("search_orders", "order_number" => "SV-100237")["orders"].first
      expect(order).to include("status" => "shipped", "tracking_code" => "BR123456789BR")
    end
  end

  describe "the cart" do
    # Task 08 depends on this: a harness with no provenance gate reaches the store and
    # the store refuses, which is a different row from a harness that refused itself.
    it "refuses an id no search returned, and says what to do instead" do
      out = call("add_to_cart", "product_id" => "999999")
      expect(out[:ok]).to be(false)
      expect(out[:payload]["error"]).to include("search first")
      expect(state.cart_items).to be_empty
    end

    it "refuses a product that cannot ship" do
      expect(call("add_to_cart", "product_id" => BATOM)[:ok]).to be(false)
      expect(state.cart_items).to be_empty
    end

    # Task 09: two units is one line with qty 2, whether the harness sends one call or
    # two. The store must not be the reason a duplicate looks fine.
    it "merges a repeated add into one line" do
      call("add_to_cart", "product_id" => ANTIATRITO)
      call("add_to_cart", "product_id" => ANTIATRITO)
      expect(state.dump["cart_items"]).to eq([{ "product_id" => ANTIATRITO, "name" => state.product(ANTIATRITO)["name"],
                                                "qty" => 2, "unit_price" => 49.9 }])
    end

    it "removes what the customer changed their mind about" do
      call("add_to_cart", "product_id" => MASC)
      call("remove_from_cart", "product_id" => MASC)
      expect(state.dump["cart_items"]).to be_empty
      expect(call("remove_from_cart", "product_id" => MASC)[:ok]).to be(false)
    end
  end

  describe "the order" do
    it "is the cart, priced, and the cart is handed over rather than left behind" do
      call("add_to_cart", "product_id" => ANTIATRITO)
      call("add_to_cart", "product_id" => SABONETE)
      out = call("create_order")

      expect(out[:ok]).to be(true)
      expect(out[:payload]["order"]).to include("total" => 84.8)
      dump = state.dump
      expect(dump["orders"].size).to eq(2)   # the fixture's, plus this one
      expect(dump["cart_items"]).to be_empty
    end

    it "refuses to close an empty cart" do
      expect(call("create_order")[:ok]).to be(false)
      expect(state.dump["orders"].size).to eq(1)
    end
  end

  # Several harnesses cannot report their own tool calls, and the ones that can are
  # reporting on themselves. The store saw all of them.
  describe "the call log" do
    it "records every call with how it ended, and hands over only what is new" do
      post("/mcp", "jsonrpc" => "2.0", "id" => 1, "method" => "tools/call",
                   "params" => { "name" => "search_products", "arguments" => { "query" => "kaiak" } })
      mark = state.calls.size
      post("/mcp", "jsonrpc" => "2.0", "id" => 2, "method" => "tools/call",
                   "params" => { "name" => "add_to_cart", "arguments" => { "product_id" => "999999" } })

      _, _, body = get("/admin/calls?since=#{mark}")
      answer = JSON.parse(body.first)
      expect(answer["count"]).to eq(2)
      expect(answer["calls"]).to eq([{ "name" => "add_to_cart", "status" => "error" }])
    end

    it "rides the dump, so a grader can say what never arrived" do
      post("/mcp", "jsonrpc" => "2.0", "id" => 1, "method" => "tools/call",
                   "params" => { "name" => "view_cart", "arguments" => {} })
      expect(state.dump["tool_calls"]).to eq([{ "name" => "view_cart", "status" => "ok" }])
    end

    it "is not readable as a tool" do
      expect(tools.list.map { |t| t["name"] }).not_to include("calls", "admin_calls")
    end
  end

  it "dumps the collections the tasks grade, and reset puts the fixture back" do
    call("add_to_cart", "product_id" => ANTIATRITO)
    call("create_order")
    expect(state.dump.keys).to include("products", "faqs", "cart_items", "orders", "support_tickets")

    state.reset
    expect(state.dump["orders"].size).to eq(1)
    expect(state.dump["cart_items"]).to be_empty
  end

  # The fixture is a file, and a task run must not be able to edit the file it is
  # graded against.
  it "never writes the seed back to disk" do
    before = File.read(seed_path)
    call("add_to_cart", "product_id" => ANTIATRITO)
    call("create_order")
    expect(File.read(seed_path)).to eq(before)
  end

  def post(path, body)
    app.call("REQUEST_METHOD" => "POST", "PATH_INFO" => path,
             "rack.input" => StringIO.new(JSON.generate(body)))
  end

  def get(path)
    route, query = path.split("?", 2)
    app.call("REQUEST_METHOD" => "GET", "PATH_INFO" => route, "QUERY_STRING" => query.to_s)
  end
end
