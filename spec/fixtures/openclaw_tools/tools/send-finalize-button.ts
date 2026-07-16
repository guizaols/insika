import { Type } from "@sinclair/typebox";
import { callAgentTool, formatToolResponse } from "../lib/api-client.js";

// endpoint ≠ name: name "send_finalize_button", slug "finalize_button" (R6).
// String com minLength/maxLength (constraints do subset). side_effect = true
// (não é read search_/get_/list_). Grupo derivado = default.
const parameters = Type.Object({
  message: Type.String({
    description: 'Texto CURTO guiando a cliente ao botão "Finalizar pedido".',
    minLength: 5,
    maxLength: 600,
  }),
});

export function createSendFinalizeButtonTool(ctx: any) {
  return {
    name: "send_finalize_button",
    label: "Botão Finalizar Pedido",
    description: "Renderiza UMA mensagem com o texto + o botão Finalizar embutido.",
    parameters,
    async execute(_toolCallId: string, params: any) {
      const result = await callAgentTool("finalize_button", params, ctx);
      return { content: [{ type: "text" as const, text: formatToolResponse(result) }] };
    },
  };
}
