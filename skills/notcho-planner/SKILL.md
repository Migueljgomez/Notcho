---
name: notcho-planner
description: Plan work into Notcho (the notch planner) in the person's own style. Use when someone asks to plan their day, a deadline, a sprint, a project's milestones, or to turn a messy list into a plan with tasks and time blocks.
---

# Notcho planner

Turn a goal into Notcho tasks with estimates and subtasks, put them on days, block time on the calendar, and leave a handoff on the project's plan page. The rule the app is built on: **plan only what fits**.

Use only Notcho's MCP tools (server name `notch`). Their descriptions explain the arguments.

## Styles

| Style | Pick when | File |
|---|---|---|
| Today | It has to be done by the end of today | [styles/today.md](styles/today.md) |
| By a date | Tomorrow, or a set deadline within about a week | [styles/by-date.md](styles/by-date.md) |
| Sprint | A 1 to 2 week push with a clear outcome | [styles/sprint.md](styles/sprint.md) |
| Milestones | A bigger project in phases, weeks or months long | [styles/milestones.md](styles/milestones.md) |
| Brain dump | A messy list that needs sorting into a plan | [styles/brain-dump.md](styles/brain-dump.md) |

To add a style, add a file to `styles/` covering the same points as the others (horizon, tasks, blocks, plan page) and add a row here.

## Steps

### 1. Read the current state

- `list_today` for today's tasks, blocks, overdue and upcoming work.
- If a project is named, `get_project` for its plan page and tasks. If the name is unclear, `list_projects` or `search`.
- On the plan page, find the last `## Planning style` section and the last `## Handoff` section. The last one on the page is the current one. Read the rest of the page (goals, decisions, next steps) as context and leave it as written.

Done when you know the open tasks, the latest handoff, and whether a style is saved.

### 2. Pick the style and hours

- **Saved style:** use it and say so in one line ("Planning in Sprint style, 9am to 5pm. Say 'switch to Milestones' to change.").
- **No saved style:** ask one short question with the five styles, plus their working hours and any fixed breaks (like lunch) if you don't know them. Keep breaks free of blocks. If the request already makes the style obvious ("finish this today"), propose that style and move on.
- The person can switch styles at any time. Switching only changes how the rest of the plan is made, not tasks already done.

Then read that style's file. It sets the horizon, task size, how far ahead to block time and what extra goes on the plan page. Where it differs from these steps, the style file wins.

### 3. Break the goal into tasks

- Each task is one sitting: a verb-first title, an estimate in minutes, 90 minutes at most. Split anything bigger.
- Give a task subtasks when it has 3 or more distinct steps.
- Reuse open tasks that already cover the work, by id, instead of adding duplicates.

Done when every piece of the goal maps to a task with an estimate.

### 4. Fit it to the time available

The horizon covers working days only: skip days outside their hours (weekends, unless they say otherwise) and days with an all-day event that means time off (a holiday, vacation, out of office). If an all-day event is unclear, ask.

For each working day in the horizon, call `read_day`. Free time is the working hours minus events, existing blocks, and the estimates of tasks already planned that day without a block (from any project). Fill each day to at most about 80% of its free time; the rest is buffer.

- Order tasks by dependency first, then by importance.
- Place each task on the earliest day it fits, unless the style says to spread work out.
- A task that waits on someone else (files, a reply, an approval) goes as late as its dependents allow, with a note naming what it waits on.
- Whatever does not fit goes to `someday` (or a later phase, in Milestones). Never squeeze it in.

Done when every task has a day or is marked as not fitting.

### 5. Show the draft and wait

Show one compact table: day, start time, task, estimate, and "new" or "existing". New tasks are your proposed scope, so this is where the person confirms it. Below it, list what did not fit and why, in one line each. Ask for a yes before writing anything. Apply changes they ask for and show the draft again.

### 6. Write it to Notcho

In this order, by id:

1. `create_project` if the project doesn't exist yet.
2. `add_task` for each new task with `project`, `day` (YYYY-MM-DD), `time_limit_minutes` (the estimate) and short `notes`. Move existing tasks with `update_task`, where the estimate is `estimate_minutes`. Set `due` and `goal` on both when the style asks for them.
3. `update_task` with `add_subtasks`, one per line.
4. `block_time` with the task id, `date` and `start`, for the days the style says to block. Add the task before blocking it, since `block_time` creates a new task when no id matches. If it reports an overlap, move the block to the next free slot.

Done when `get_project` shows every task in the approved draft under the project, with its day and block.

### 7. Leave the handoff

Append to the plan page with `update_plan` (mode `append`, never `replace`):

```markdown
## Planning style
Style: Sprint · Hours: 9am to 5pm · Notes: no blocks before 10am

## Handoff (YYYY-MM-DD)
- Goal: the outcome and its date
- Decisions: what was chosen and why, one line each
- Planned: what is on which days
- Did not fit: what went to someday
- Waiting on: who or what, and the fallback (omit if nothing)
- Next: the first thing a fresh chat should do
```

Write the `## Planning style` section only when the style or hours are new or changed. Add any style-specific extras from the style file. With no project (a plain day plan), skip the plan page and give the handoff in chat.

### 8. Report

Reply in a few lines: how many tasks were added or moved, which days, how many blocks, and what did not fit. End there.
