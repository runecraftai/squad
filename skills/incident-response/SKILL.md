---
name: incident-response
description: >-
  Handle production incidents with a structured response: detect, contain, diagnose, remediate, and review.
  Use when a production system is failing, degraded, or has caused user impact.
license: MIT
metadata:
  source: tech-leads-club/agent-skills
  source-license: MIT
  attribution: Reconstructed for Runecraft
user-invocable: true
---

# Incident Response

Use this skill when a production system is failing or degraded.
Follow a structured response to minimize impact, diagnose root cause, and prevent recurrence.

## Response phases

### 1. Detect

- Confirm the incident: what is failing, who is affected, how severe.
- Check monitoring dashboards, logs, and alerts.
- Determine if the incident is user-facing or internal.

### 2. Contain

- Stop the bleeding: roll back, disable the feature, or route around the failure.
- Communicate the incident status to stakeholders.
- Preserve evidence: capture logs, metrics, and the current state before remediation.

### 3. Diagnose

- Identify the root cause using the evidence collected.
- Check recent deployments, configuration changes, and dependency health.
- Distinguish symptoms from causes.
- Document hypotheses and the evidence that supports or rules each one out.

### 4. Remediate

- Apply the fix: code change, configuration update, or infrastructure adjustment.
- Verify the fix resolves the symptoms without introducing new issues.
- Monitor for regression after deployment.

### 5. Review

- Write a blameless post-incident review.
- Capture timeline, root cause, impact, remediation, and preventive actions.
- Create follow-up tasks for preventive measures.
- Update monitoring or alerts if the incident was not caught quickly enough.

## Severity classification

| Level | Impact | Response time |
|---|---|---|
| SEV1 | Full outage or data loss | Immediate |
| SEV2 | Major feature degraded | Within 1 hour |
| SEV3 | Minor feature affected | Within 4 hours |
| SEV4 | Cosmetic or low-impact | Next business day |

## Do not use for

- Local development issues or bugs with no production impact.
- Planned maintenance or deployments.
- Security incidents that require a separate security response process.
