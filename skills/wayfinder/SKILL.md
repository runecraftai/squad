---
name: wayfinder
description: Turn a large uncertain initiative into a dependency-aware map of decisions and research questions.
license: MIT
metadata:
  source: mattpocock/skills
  source-license: MIT
  attribution: Reconstructed for Runecraft
---

# Wayfinder

Use this skill when an initiative is too large for one session and the route is unclear.
The output is a decision map, not an excuse to start implementation prematurely.

## Chart the route

1. Name the destination and define what reaching it means.
2. List the decisions that could change the destination, scope, or implementation order.
3. Separate decisions from execution tasks.
4. Add dependencies so a decision is not taken before the evidence it needs.
5. Mark unknown future questions as fog rather than inventing premature tickets.
6. Identify the first unblocked question and its owner.

Use the project's issue tracker when one is configured.
If no tracker exists, create a concise `WAYFINDER.md` map with links or stable headings.
Name decisions in human-readable language rather than bare issue numbers.

## Resolve the map

Work one decision at a time.
Capture the answer where the question lives, then update the map with a one-line summary.
Research questions may run in parallel when their evidence is independent.
Do not close the map until no decision remains that could change the chosen route.
Hand the cleared route to the implementation planner.

## Example

Destination: "Ship tenant-aware reporting."

First questions: "What is the tenant isolation rule?", "Which reports must be real time?", and "What is the retention window?"

A task such as "build the report endpoint" belongs after those decisions, not on the decision map.

## Do not use for

- A feature whose requirements and implementation path are already clear.
- A normal task breakdown after the route has been decided.
- A tracker migration or project-management administration request.
