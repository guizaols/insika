---
title: Studio
parent: Operate
nav_order: 0
permalink: /studio/
---

# Studio — the operator UI

The Studio is the web UI at `/studio`. Sign in with `ADMIN_TOKEN` (see
[Deploy](DEPLOY.md#environment-variables)). This page covers the screens for
watching conversations, reviewing what waits on a person, and seeing what a
change did. Model metrics are on [Observability](OBSERVABILITY.md#studio-models).

Outside production, a banner above every page names the environment
(`INSIKA_ENV`, else `RACK_ENV`, else `local`): amber for staging, blue for
anything else. Production (`production` or `prod`) shows no banner.

## Navigation

The sidebar groups pages as Operate, Review, Build, Insights and Platform. Each
Review page shows a badge with how many items wait on it. `⌘K` (or Search in the
sidebar) opens a palette that jumps to any page or agent.

## Overview

`/studio/home`. The Overview shows the headline numbers for the agent filter and
a **Needs attention** row. The row lists the review queues, customers waiting for
a reply and tools failing in the last 24 hours, each linking to its page. Only
non-zero items show.

## Live

`/studio/live` shows one card per recent conversation: customer, agent, the last
message, a presence dot (activity in the last 5 minutes) and the guardrail flag.
Cards move with the event stream. While a turn runs, a card shows the tools it
calls and "agent is writing…". A turn paused for an approval stops writing until
it resumes. A ticker lists the latest events, without the streaming deltas.

`?agent=<id>` shows only that agent's conversations.

## Chats

`/studio/chats` lists conversations with three tabs: **All**, **Active now**
(activity in the last 5 minutes) and **Guardrail flagged**, each with its count.
The session page shows the customer (key, name, phone) and links to their other
conversations.

### Why this reply

Each agent reply has a collapsed **why this reply** panel for its own turn:

- context tokens by category, and the skills injected with the reason;
- the tool calls with status and timing;
- the guardrail flags on the customer's message.

From the panel, **Replay in Playground** opens the conversation in the
Playground, and **Save as eval
case** opens the Evals editor prefilled from the reply (the customer's turns,
the transcript as the reference, the tools the turn called). A reply that
streams in live offers the panel when its turn finishes.

### Tool calls

A turn with two or more tool calls draws a waterfall of when each one ran.
Tool calls are grouped by turn within each task, since the turn number restarts
at 1 for every task.

### Markup tags

Tags an agent or a host writes in the text, like `<carrossel/>`,
`<vitrine formato="lista">` or `</b>`, show as highlighted tokens: in replies,
customer messages, and the Live and Chats previews. They are escaped and never
rendered. The channel decides what a tag does; the Studio only shows it is
there. A tag inside inline code stays code.

## Guardrail false positives

On a guardrail flag in the session page, **Mark false positive** records the
verdict on the flag itself, inside the session, so retention and tenant purges
cover it. The flag can later be marked resolved, or the verdict undone.
Reviewing a flag does not count as conversation activity: the session keeps its
place in the recent lists. The command is `:review_guardrail_flag`.

## Inbox

`/studio/inbox` is one list, oldest first, of everything that waits on a person:
approvals, fact proposals, mined skills, refinement runs and reported guardrail
false positives. Tabs filter by type, with counts. Each row opens the page where
the item is decided.

## Agent History

The **History** tab of an agent shows outcomes per day over the last 30 days:
the funnel's primary outcome when the agent declares a funnel, else all
outcomes. A dashed line marks each change to a prompt file or to one of this
agent's own skills (shared skills change for every agent, so they are not
marked).

Under the chart, one card per change shows the file or skill, when, a short line
diff, and the outcomes in the 7 days after against the 7 days before. A window
that is not complete yet, or that starts before the outcome data, reads "not
enough data". A prompt card has the Restore form; a skill card links to the
skill.

## Funnel: where conversations stop

The Funnel page marks the biggest loss between two consecutive declared stages.
Each loss opens (`?drop=<stage>`) the conversations that reached the stage but
not the next one in the period, grouped by the last thing that happened:

| Reason | Meaning |
|--------|---------|
| Last tool call failed | the conversation's last tool call returned an error |
| A guardrail flagged a message | a guardrail flagged one of its messages |
| Customer waiting on a reply | the customer wrote last |
| Customer went quiet after the agent's reply | the agent wrote last |
| No message to read | the conversation has no message to classify |
| Conversation no longer stored | the conversation was deleted |

Only the newest 200 stuck conversations are classified; the page says how many
were left out.
