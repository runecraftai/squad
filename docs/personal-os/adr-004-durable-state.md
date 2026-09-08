# ADR-004: Durable state

Squad's existing task records remain the source of truth.

The MCP process keeps no second task database.

A new MCP process can recover a task by calling the current-state owner with its `taskId`.
