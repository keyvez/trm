+++
title = "Command Center"
description = "The board of every agent in every trm window: what each one is saying, what needs you, and a reply box on every row."
weight = 4
+++

The Command Center is one list of every AI agent running in every trm window —
what each is saying right now, which ones are blocked, which ones failed, and a
box to answer any of them without going to its pane.

Open it with **⌘⇧A**, or **View → Command Center**. It opens as a panel along
the window's trailing edge and is remembered across launches, per app rather
than per window: it is a way of working, not a property of one layout.

## What a row says

Every pane running an agent gets a row, in the order the panes are laid out —
the board is a view *of* your grid, so a row is where you expect it to be. What
it needs is carried by a coloured bar and a label rather than by position:
**needs you** (orange) when the agent has asked a question and is blocked,
**check this** (red) when tool calls failed this turn, **working** (green) while
it is mid-task, and **idle** when it has stopped and is waiting for you. A row
also carries the pane's watermark, which agent is in it, the project directory
(a worktree shows its branch name), the machine when the pane is remote, and
how long ago the pane last said anything.

Under the summary, one escalation line appears only when something actually
wants a decision — the question you have not answered, or the errors and what
the last one said. Its presence is the signal.

Panes whose agent is still being located hold their place rather than
disappearing — a remote pane's transcript has to come over SSH first, and a
board that is briefly short is worse than one that says "resolving".

Links are pulled out of the agent's message whole and listed under it. A
truncated URL is worthless, and the server address an agent just printed is the
single most grabbable thing on the board.

## Briefing mode

The target button in the panel header switches the board from "what each agent
is saying" to a briefing: a headline per agent, and under it a few sentences of
what actually happened.

The lines are **prose about the work, not a list of commands**. `Bash: npm
test` names what ran, not what came of it — and the terminal one pane away is
already showing it. What a briefing carries instead is what changed and why,
what the numbers were, what the error actually said, and what is still
unfinished.

With an LLM configured (see [Configuration](/docs/configuration/)), the
summariser writes them, and it is told which state the pane is in — working,
blocked on a question, stopped — along with what failed, because a summariser
given only the words writes a report on a finished turn even when the agent is
mid-tool.

With no LLM configured, or while a summary is still being written, the row
falls back to the agent's own account of the turn: its opening sentence, then
the paragraphs under it, with fenced code left out and list markers stripped
while their text stays. That fallback is rebuilt from the pane on every scan,
so it can never describe a turn that has moved on.

## The question an agent is asking

An agent that has stopped to ask "may I run this?" or "may I make this edit?"
is the most urgent thing on the board, and it is the one thing a transcript
cannot report: those prompts are drawn and answered entirely in the terminal
and never reach the JSONL. `AskUserQuestion` does reach it, but not until the
turn moves on — so both kinds of question used to arrive at the board at the
moment they stopped being questions.

trm reads them off the pane's own screen instead. A row with a question shows:

- **the question**, above everything else the row has to say;
- **the preview** — the diff, the plan, the command about to run — drawn from
  the pane's actual cells, in the colours the terminal drew them in;
- **the choices as buttons**. Clicking one sends that digit to the pane and
  nothing else: these menus act on the digit, and a Return behind it would land
  in whatever the agent draws next.

The same question, its options and a plain-text preview go to the phone, which
can answer it back.

The detector is deliberately hard to please: two or more consecutively numbered
choices, at the bottom of the screen, with the cursor resting on one of them.
That last rule is what separates a menu from the numbered list an agent writes
when it reports three things it fixed, and it is also the liveness test — the
cursor belongs to the menu that is taking input, and what is left after an
answer is the echoed choice without it. Where the shape is not unmistakable the
row shows what it always showed.

Because the pane's surface renders locally, this works for remote panes too.

## Full view

The expand button in the panel header gives the board the whole window: cards
laid out as a grid, no terminal panes on screen. Press it again to go back to
the strip.

The panes are not closed or rearranged — full view is drawn *over* the grid, so
nothing is resized on the way in or out and every terminal comes back exactly
as it was. Like the panel itself, the mode is remembered across launches.
Hiding the Command Center from full view leaves the window on its panes rather
than on a takeover waiting to reappear.

## Replying from the board

Every row has a reply box. What you type goes to that pane's agent as a paste
followed by a Return, so a message written over several lines arrives with its
line breaks intact rather than folded into one line.

| Gesture | What it does |
|---------|--------------|
| Click a row | Put the cursor in its reply box |
| ⌘-click a row | Open that pane's Agent Overview |
| Double-click the header | Go to the pane itself |
| Double-click the watermark | Rename the pane |
| Drop a file or image on a row | Attach it to the message |
| Right-click a row | Row menu, including closing the pane |

Previous messages to that agent are offered back, so an instruction you send
often does not have to be retyped.

## On your phone

**View → Pair iPhone…** shows a QR code that hands a phone the address and a
token. The phone then has the same board — who is stuck, what each agent just
said, the same briefing lines, and a box to reply into any of them. It reads
the same turns the Mac draws rather than re-deriving them, so the two cannot
disagree.

The Mac serves this over the local network, so it needs the Local Network
permission granted to trm.

## Shortcuts

| Shortcut | Action |
|----------|--------|
| `Cmd+Shift+A` | Toggle the Command Center panel |
| Drag the panel's inner edge | Resize it (it may take most of the window) |
