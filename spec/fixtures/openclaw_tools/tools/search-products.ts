import { Type } from "@sinclair/typebox";
import { callAgentTool, formatToolResponse } from "../lib/api-client.js";

// Param ANINHADO: array de objetos { query, filters }, com filters.price aninhado.
// Prova que o conversor reconstrói JSON Schema aninhado de verdade (não flat).
const parameters = Type.Object({
  query_filter_pairs: Type.Array(
    Type.Object({
      query: Type.String({
        description: "Termo CURTO de busca (2 a 5 palavras).",
      }),
      filters: Type.Optional(
        Type.Object(
          {
            price: Type.Optional(
              Type.Object(
                {
                  min: Type.Optional(Type.Number()),
                  max: Type.Optional(Type.Number()),
                },
                { additionalProperties: false },
              ),
            ),
            color: Type.Optional(Type.Array(Type.String())),
          },
          { additionalProperties: true },
        ),
      ),
    }),
    { minItems: 1 },
  ),
  catalog_mode: Type.Optional(
    Type.Boolean({ description: "true = catálogo geral; false = busca específica" }),
  ),
});

export function createSearchProductsTool(ctx: any) {
  return {
    name: "search_products",
    label: "Buscar Produtos",
    description: "Busca produtos do catálogo da loja. Passe query_filter_pairs.",
    parameters,
    async execute(_toolCallId: string, params: any) {
      const result = await callAgentTool("search_products", params, ctx);
      return { content: [{ type: "text" as const, text: formatToolResponse(result) }] };
    },
  };
}
