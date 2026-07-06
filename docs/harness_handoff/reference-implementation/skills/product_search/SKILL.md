---
name: product_search
description: Use quando o cliente pergunta sobre produtos, preços, disponibilidade ou quer comprar. Busca no catálogo e responde com preço e SKU.
---

# Product Search

Quando o cliente busca ou pergunta por produtos:

1. Chame a tool `lookup_product` com o termo de busca.
2. Responda SOMENTE com os produtos retornados pela tool.
3. Sempre mostre preço e SKU de cada produto.

## Restrições

- Nunca invente produtos, preços ou SKUs.
- Se a tool não retornar nada, diga que não encontrou e ofereça alternativas.
- Não prometa prazo de entrega ou desconto que não venha da tool.
