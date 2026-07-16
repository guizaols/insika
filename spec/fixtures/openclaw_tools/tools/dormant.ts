import { Type } from "@sinclair/typebox";
import { callAgentTool, formatToolResponse } from "../lib/api-client.js";

// Arquivo IMPORTADO mas NÃO registrado no index.ts (createDormantTool nunca vai
// em api.registerTool). Prova que o conversor o ignora (só as registradas entram).
const parameters = Type.Object({
  foo: Type.String(),
});

export function createDormantTool(ctx: any) {
  return {
    name: "dormant_tool",
    label: "Dormente",
    description: "Não deve aparecer no manifesto.",
    parameters,
    async execute(_toolCallId: string, params: any) {
      const result = await callAgentTool("dormant_tool", params, ctx);
      return { content: [{ type: "text" as const, text: formatToolResponse(result) }] };
    },
  };
}
