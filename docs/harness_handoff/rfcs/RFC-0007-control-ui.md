---
rfc: "0007"
title: Control UI (Operator Frontend)
status: Draft
type: Componente
created: 2026-07-05
supersedes: []
depends_on: ["0001", "0002", "0006"]
---

# RFC-0007 — Control UI (Operator Frontend)

> Detalha o frontend do Harness. Espelha o modelo do **Control UI do OpenClaw**:
> um painel de operador servido pelo próprio serviço, na mesma porta, como
> **admin surface** — não uma UI de usuário final.

## 1. O que é (e o que não é)

O Harness é headless. Ele tem **um** frontend, e é para o **operador**, não para
o usuário final.

- **UI de usuário final** — não existe no Harness. Para o Agent.Shop, o "frontend"
  do usuário é o WhatsApp, cujo dono é o Agent.Shop. Um chat web de usuário final,
  se desejado, é **outro app consumidor** da API (irmão do Agent.Shop), fora deste
  RFC. (No OpenClaw, o equivalente é apontar um Open WebUI para o endpoint
  compatível com OpenAI; conversa fica lá, gestão fica no Control UI.)
- **Control UI (operador)** — o painel de administração/observabilidade. É o
  análogo do Control UI do OpenClaw e do Sidekiq Web.

## 2. Modelo (fiel ao OpenClaw)

No OpenClaw, o Control UI é servido pelo próprio Gateway, na mesma porta, e é
explicitamente um admin surface (chat, config, aprovação de exec). O Harness
adota o mesmo: **o Control UI faz parte do `harness-server`**, servido junto, na
mesma porta. Não é um projeto separado nem uma gem que o consumidor precisa subir
à parte.

Opção secundária (como no ecossistema Rails): montável num app externo
(`mount Harness::Web at "/harness"`), para quem quiser embutir. Mas o **default é
vir no serviço**.

## 3. Telas

As telas são o mapa das quatro plataformas (RFC-0001) virando interface. Espelham
as páginas do OpenClaw (Chat, Sessions, Config, Nodes, Logs, Skills), adaptadas:

| Tela            | Função                                              | Plataforma / RFC |
|-----------------|-----------------------------------------------------|------------------|
| **Chat**        | testar o agente direto no painel                    | Execution        |
| **Sessions**    | inspecionar conversas persistidas                   | Persistence 0006 |
| **Tasks**       | ver/inspecionar execuções; **pause/resume/approve** | Execution 0002   |
| **Skills**      | navegar o Skill Catalog (SKILL.md)                  | Context 0005     |
| **Tools/Plugins**| navegar os Registries; testar tools                | Extensibility 0003 |
| **Config**      | perfis de agente, políticas (allow/deny)            | Context/Policy   |
| **Events/Logs** | Event Stream ao vivo                                | Execution 0002   |

O **human-in-the-loop** vive na tela Tasks: aprovar/rejeitar ações pendentes via
o Command `ApproveAction` (RFC-0002 §Actor mailbox `approval`).

## 4. Tecnologia — decisão `[divergência do OpenClaw]`

O OpenClaw usa SPA (Vite + Lit) + WebSocket. O Harness usa **server-rendered
(Hotwire/Turbo) + o SSE que já existe**, não SPA.

Racional: o SSE do Event Stream (RFC-0002 §7.4) já é o contrato de streaming e já
alimenta os consumidores. Reusá-lo no painel evita manter um segundo canal (WS) e
um build de frontend separado — menos peça móvel, fiel ao princípio "núcleo
pequeno". A mesma `/events` que informa o Agent.Shop informa o painel ao vivo.

WebSocket entra só se/quando o painel precisar de chat bidirecional rico; até lá,
SSE + POSTs de Command bastam.

O painel **consome os mesmos endpoints** que qualquer cliente (RFC-0002 §Service):
não é um caminho especial, é só mais um cliente da API. Coerente com "uma
pipeline, um contrato".

## 5. Segurança — admin surface

O OpenClaw repete em toda a doc: o Control UI **nunca** vai exposto publicamente.
O Harness herda a regra como requisito:

- O Control UI é **separado do endpoint que o consumidor usa**. No deploy do
  Agent.Shop (EKS), o `/admin` fica atrás de auth forte / rede interna / túnel; o
  endpoint de API que o Agent.Shop consome é outra rota, com seu próprio auth.
- Autenticação de operador obrigatória (token/senha/identidade de proxy
  confiável). Nunca `bind` público sem auth.
- Ações destrutivas (cancel, aprovar exec, editar config) exigem sessão de
  operador autenticada; toda ação emite evento de auditoria no Event Stream.
- `allowedOrigins` explícito para qualquer deploy não-loopback.

## 6. Empacotamento

- `harness` (core) — sem UI.
- `harness-server` — Service Platform **+ Control UI** servido na mesma porta
  (rota `/admin` por default, configurável). É o processo standalone.
- Montagem externa opcional (`Harness::Web`) para embutir num app existente.

## 7. Questões em Aberto

1. Autorização granular (papéis: read-only vs operador vs admin)?
2. Multi-tenant: o painel escopa por tenant ou é global do operador?
3. Chat do painel reusa a mesma Session API ou tem sessões de "operador"
   separadas das de produção?
