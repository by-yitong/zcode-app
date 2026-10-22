# Case Scope

## meta
- case_id: 20261020-213606-zcode-remote-v4-web
- created: 2026-10-20T21:36:06+08:00
- operator: local
- project_root: /home/admins/projects/zocde-app
- primary_skill: reverse-engineering/SKILL.md
- primary_id: R0
- lead_role: lead
- specialist_roles: []
- hint: zcode-remote-v4-web
- preset: none

## auth
- status: granted
- basis: own_system
- evidence_of_auth: user-directed analysis of the zcode.z.ai web client the user legitimately uses; read-only fetch of publicly served frontend assets (HTML/JS) equivalent to browser+DevTools; NO auth bypass, NO credential use, NO scanning, NO attack
- MUST NOT proceed if status != granted

## in_scope
- assets:
  [https://zcode.z.ai/remote/v4 and its publicly served static frontend assets (HTML/JS/CSS)]
- surfaces: [web]
- activities: [passive_fetch, static_js_analysis, report]

## out_of_scope
- assets: []
- activities: [dos, phishing_real_users, unrestricted_exfil]

## network_profile
- mode: authorized_target_only
- notes: |
    GET-only fetch of zcode.z.ai public frontend assets for static analysis.
    Forbidden: auth bypass, login brute force, credentialed API calls, scanning, load, screenshots.

## deliverables
- report: true
- field_journal: true
- diagrams: true
- timeline: true

## constraints
- timebox: {}
- stealth: low
- data_handling: anonymize

## signoff
- ready_for_act: true
- checklist:
  - [x] auth.status = granted
  - [x] in_scope.assets non-empty OR offline sample path set
  - [x] network_profile.mode chosen
  - [x] out_of_scope reviewed
  - [ ] roles assigned (see skills/ops/role-map.md)

## ops_refs
- skills/ops/scope-contract.md
- skills/ops/evidence-finding-path.md
- skills/ops/role-map.md
- skills/ops/timeline-workitem.md
- skills/ops/IDENTITY.md
