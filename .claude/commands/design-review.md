---
allowed-tools: Read, Grep, Glob, Bash, Agent
description: Design review of Claudometer's UI (renders every state, then runs the design-review agent)
---

GIT STATUS:

```
!`git status --short`
```

CHANGED FILES (working tree vs last commit, if any):

```
!`git diff --name-only HEAD 2>/dev/null || echo "(no commits yet — review the whole UI)"`
```

OBJECTIVE:
1. Build and render every state:
   `swift build && B=$(swift build --show-bin-path)/Claudometer && $B --render-previews review/renders && for s in high rings pinned stale signedout; do $B --render-previews review/renders --sample "$s"; done`
2. Use the `design-review` agent to review the renders and the UI code against `context/design-principles.md` and `context/style-guide.md`.
3. Reply with the agent's markdown report and nothing else.
