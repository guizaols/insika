# Security Policy

This file is the **disclosure policy** — how to report a vulnerability.
For what the engine *does* about security (edge limits, guardrails, approvals, the
egress guard, the sandbox, secret handling), see **[docs/SECURITY.md](docs/SECURITY.md)**.

## Reporting a vulnerability

**Do not open a public issue.**

Use GitHub's private reporting: the repository's **Security** tab →
**Report a vulnerability**. That opens a draft advisory visible only to you and the
maintainers.

Helpful to include:

- the version or commit you tested,
- what an attacker gets (read data across tenants? execute code? exhaust budget?),
- a minimal reproduction — a failing spec is ideal,
- your configuration, with keys redacted.

Insika is maintained by one person as a pre-release project. Expect an
acknowledgement within about 5 business days. There is no bug bounty. Credit in the
advisory is yours unless you'd rather stay anonymous — please give us a chance to ship
a fix before publishing.

## Supported versions

Pre-release: only the latest `main` is supported. There are no backports and no
security branches yet. When the first tagged release ships, this section will say
which versions receive fixes.

## In scope

Anything that lets input crossing the engine's boundary do something the operator did
not configure:

- bypassing a **policy** layer — tool/skill allowlists, model policy, approvals;
- escaping the **sandbox** or the **egress guard** (SSRF, reaching private hosts a
  tool manifest does not allow);
- **cross-tenant or cross-session leakage** — one chat reading another's transcript,
  memory, tasks, or files;
- **secret exposure** — a key reaching a store, a transcript, an event, an SSE frame,
  or a log;
- authentication or authorization flaws in the HTTP surface (`/v1/*`, `/a2a/*`) or the
  Studio, including the onboarding surface when it is enabled;
- injection into the persistence layer, or a crafted pack/manifest/skill that escalates
  what an agent can reach.

## Out of scope

- **An LLM producing bad output.** A model that says something wrong, rude, or
  jailbroken is not a vulnerability here. Guardrails are probabilistic and documented
  as such. A guardrail that can be *bypassed structurally* — never invoked, or skipped
  by a code path — **is** in scope.
- **Configuration you chose.** Running with the egress guard open, approvals off, or
  `INSIKA_ONBOARDING=1` in production is a deployment decision; the defaults and their
  trade-offs are documented in [docs/DEPLOY.md](docs/DEPLOY.md).
- **Vulnerabilities in dependencies** — report those upstream (`ruby_llm`, Falcon,
  SQLite, …). If Insika *uses* one unsafely, that part is ours.
- Tools you wrote, provider outages, and denial of service from a load level you
  configured no limit for.
