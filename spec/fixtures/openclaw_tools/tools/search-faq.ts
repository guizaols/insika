import { Type } from "@sinclair/typebox";
import { callAgentTool, formatToolResponse } from "../lib/api-client.js";

// endpoint ≠ name: name "search_faq", slug "search_faqs" (R6). Param simples,
// grupo derivado = core. side_effect = false (prefixo search_).
const parameters = Type.Object({
  query: Type.String({
    description: "Termo descritivo completo para busca no FAQ.",
  }),
});

export function createSearchFaqTool(ctx: any) {
  return {
    name: "search_faq",
    label: "Buscar FAQ",
    description: "Busca na base de conhecimento da loja (FAQs institucionais).",
    parameters,
    async execute(_toolCallId: string, params: any) {
      const result = await callAgentTool("search_faqs", params, ctx);
      return { content: [{ type: "text" as const, text: formatToolResponse(result) }] };
    },
  };
}
