// Pi ships NO MCP, on purpose: its docs say so in as many words — "it intentionally
// does not include built-in MCP … you can build or install those workflows as
// extensions". So this is the smallest possible bridge: at session start it lists the
// store's tools over MCP and registers each one as a Pi tool, passing the server's
// own JSON Schema straight through.
//
// This is the bench's code, not Pi's, and the report says so beside its row. It is
// the least we could add and still reach the same store; anything cleverer here would
// be measuring us instead of the harness.
const ENDPOINT = process.env.BENCH_STORE_MCP;

async function rpc(method, params) {
  const res = await fetch(ENDPOINT, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ jsonrpc: "2.0", id: Math.floor(Math.random() * 1e6), method, params })
  });
  const body = await res.json();
  if (body.error) throw new Error(body.error.message || "mcp error");
  return body.result;
}

export default function (pi) {
  pi.on("session_start", async (_event, ctx) => {
    let tools;
    try {
      await rpc("initialize", {});
      tools = (await rpc("tools/list", {})).tools || [];
    } catch (e) {
      ctx.ui.notify(`store MCP unreachable: ${e.message}`, "error");
      return;
    }

    for (const tool of tools) {
      pi.registerTool({
        name: tool.name,
        label: tool.name,
        description: tool.description || tool.name,
        parameters: tool.inputSchema || { type: "object", properties: {} },
        async execute(_toolCallId, params) {
          const result = await rpc("tools/call", { name: tool.name, arguments: params || {} });
          return { content: result.content, details: {}, isError: !!result.isError };
        }
      });
    }
  });
}
