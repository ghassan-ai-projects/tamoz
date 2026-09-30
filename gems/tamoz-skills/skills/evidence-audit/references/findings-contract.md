# findings.json, field by field

The JSON Schema is `assets/findings.schema.json`. `scripts/verify_findings.rb` enforces it and
more.

```json
{
  "audit": {
    "title": "Access-control policy review",
    "criteria_source": "criteria.md",
    "prepared_by": "tamoz",
    "prepared_at": "2026-10-01T10:00:00Z"
  },
  "sources": [
    { "path": "policies/access.md", "sha256": "bce2aeea…(64 hex, as read_file prints it)" }
  ],
  "criteria": [
    { "id": "C1", "text": "Passwords must be at least 12 characters." }
  ],
  "findings": [
    {
      "id": "F-001",
      "criterion": "C1",
      "title": "Minimum password length is 8, below the required 12",
      "conclusion": "exception",
      "severity": "high",
      "statement": "The policy sets an 8-character minimum; the criterion requires 12.",
      "reasoning": "Section 2.1 states the minimum directly; no other section raises it.",
      "evidence": [
        { "path": "policies/access.md", "lines": [14, 14],
          "quote": "Passwords must contain at least 8 characters",
          "supports": "States the minimum length." }
      ],
      "counter_evidence": [],
      "review": { "status": "proposed", "reviewer": null, "decided_at": null, "note": null }
    }
  ]
}
```

| Field | Rule |
|---|---|
| `sources[].path` | relative, inside the workspace, not under `audit/` |
| `sources[].sha256` | the digest of the file as read (hex, optionally prefixed `sha256:`) |
| `criteria[].id` | unique; every criterion needs at least one finding |
| `findings[].id` | `F-` and three digits, unique |
| `findings[].conclusion` | `exception`, `no_exception` or `insufficient_evidence` |
| `findings[].severity` | `high`, `medium`, `low` or `info`; `no_exception` is always `info` |
| `findings[].evidence` | at least one citation (see the evidence standard) |
| `findings[].review` | as prepared: `status` `proposed`, everything else `null` |
