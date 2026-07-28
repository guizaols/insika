import { Type } from "@sinclair/typebox";
import { callAgentTool, formatToolResponse } from "../lib/api-client.js";

// A param the safe subset CANNOT express (Type.Record of Any). The converter must SKIP
// the whole tool and report it — the old behaviour emitted { type: "string" } here, a
// contract the source never declared.
const parameters = Type.Object({
  freeform: Type.Record(Type.String(), Type.Any()),
});

export function createExoticTool(ctx: any) {
  return {
    name: "exotic_tool",
    label: "Exotic",
    description: "A tool whose parameters have no equivalent in the safe subset.",
    parameters,
    async execute(_toolCallId: string, params: any) {
      const result = await callAgentTool("exotic_tool", params, ctx);
      return { content: [{ type: "text" as const, text: formatToolResponse(result) }] };
    },
  };
}
