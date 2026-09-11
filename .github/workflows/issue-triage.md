---
description: |
  Automated issue triage for Azure Verified Modules Terraform module repositories. Checks for duplicates, classifies issues with existing repo labels, discovers related pull requests, links clear fixes, closes issues that are conclusively resolved, and posts a triage summary comment on new, reopened, or manually selected issues.
network:
  allowed:
  - defaults
  - github
  - learn.microsoft.com
  - registry.terraform.io
  - terraform
# Run on new issues, reopened issues, allow manual reruns
"on":
  issues:
    types:
    - opened
    - reopened
  roles: all
  workflow_dispatch:
    inputs:
      issue_number:
        description: 'Issue number to triage (required for on-demand manual runs)'
        required: true
        type: string
# The compiler-generated agent, output and conclusion jobs share a static
# concurrency group per workflow. `features.group-concurrency-queue: false`
# below strips `queue: max` from those groups, so Actions applies its default
# `single` queueing and keeps only the newest pending run — a third arrival
# discards the middle one. Fanning several issues out at once therefore lost
# conclusion jobs and their failure reports. Discriminating by issue number
# gives each dispatched run its own group. Stripped from the compiled lock.
concurrency:
  group: "gh-aw-${{ github.workflow }}-${{ github.event.inputs.issue_number || github.event.issue.number || github.run_id }}"
  job-discriminator: ${{ github.event.inputs.issue_number || github.event.issue.number || github.run_id }}
# Read-only permissions for triage
permissions:
  contents: read
  issues: read
  models: read
  pull-requests: read
  copilot-requests: write
features:
  group-concurrency-queue: false
engine:
  model: claude-sonnet-5
safe-outputs:
  runs-on: ubuntu-latest
  needs: [triage_evidence]
  data:
    type: object
    additionalProperties: false
    properties:
      version:
        type: integer
      fixing_pr:
        type: integer
        minimum: 0
      fix_confidence:
        type: string
        enum: [none, confirmed, related, partial]
      release_action:
        type: string
        enum: [none, evaluate_fix]
      human_reopen_override:
        type: boolean
      screening_complete:
        type: boolean
        description: True only after all inventory rows were actually screened and all required or plausible PRs were fully inspected.
      fully_inspected_prs:
        type: array
        description: PRs whose full diff and supporting evidence you actually inspected. Include the selected fix even outside the index; this is not the inventory screening list.
        items:
          type: integer
          minimum: 1
      screened_inventory_prs:
        type: array
        description: Every open or merged inventory PR you actually screened, including irrelevant rows and fully inspected inventory PRs. Never copy the full-inspection subset here or claim unread rows.
        items:
          type: integer
          minimum: 1
      findings:
        type: string
      audit:
        type: string
    required: [version, fixing_pr, fix_confidence, release_action, human_reopen_override, screening_complete, fully_inspected_prs, screened_inventory_prs, findings, audit]
  steps:
  - name: Prepare private triage gate directory
    id: triage-gate-directory
    uses: actions/github-script@3a2844b7e9c422d3c10d287c895573f7108da1b3
    with:
      script: |
        const fs = require('fs');
        const path = require('path');
        const directory = fs.mkdtempSync(path.join(process.env.RUNNER_TEMP, 'triage-gate-'));
        fs.chmodSync(directory, 0o700);
        core.setOutput('path', directory);
  - name: Download trusted triage evidence independently
    continue-on-error: true
    uses: actions/download-artifact@3e5f45b2cfb9172054b4087a40e8e0b5a5461e7c
    with:
      artifact-ids: ${{ needs.triage_evidence.outputs.artifact_id }}
      path: ${{ steps.triage-gate-directory.outputs.path }}/evidence
      merge-multiple: true
  - name: Enforce triage release gate
    uses: actions/github-script@3a2844b7e9c422d3c10d287c895573f7108da1b3
    env:
      GH_AW_AGENT_OUTPUT: ${{ steps.setup-agent-output-env.outputs.GH_AW_AGENT_OUTPUT }}
      TRIAGE_GATE_DIRECTORY: ${{ steps.triage-gate-directory.outputs.path }}
      TRIAGE_ARTIFACT_ID: ${{ needs.triage_evidence.outputs.artifact_id }}
      TRIAGE_MANIFEST_SHA256: ${{ needs.triage_evidence.outputs.manifest_sha256 }}
      TRIAGE_PRODUCER_ATTEMPT: ${{ needs.triage_evidence.outputs.producer_attempt }}
      TRIAGE_REPOSITORY: ${{ github.repository }}
      TRIAGE_ISSUE: ${{ github.event.inputs.issue_number || github.event.issue.number }}
      TRIAGE_WORKFLOW_SHA: ${{ github.workflow_sha }}
      GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}
    with:
      script: |
        // This code runs on the trusted output runner, not inside the agent.
        const fs = require('fs');
        const path = require('path');
        const crypto = require('crypto');
        const { execFileSync } = require('child_process');
        const runtimeDirectory = path.join(process.env.RUNNER_TEMP, 'gh-aw', 'actions');
        const directory = process.env.TRIAGE_GATE_DIRECTORY;
        const evidenceDirectory = path.join(directory, 'evidence');
        const outputPath = process.env.GH_AW_AGENT_OUTPUT;
        const proofPath = path.join(directory, 'selected-pr-release-status.json');
        const repository = process.env.TRIAGE_REPOSITORY;
        const issue = Number(process.env.TRIAGE_ISSUE);
        const positive = n => Number.isSafeInteger(n) && n > 0;
        // Native target fields also accept decimal strings. Decision/proof PRs remain typed integers.
        const targetNumber = value => {
          if (positive(value)) return value;
          if (typeof value !== 'string' || !/^[1-9][0-9]*$/.test(value)) return null;
          const number = Number(value);
          return positive(number) && String(number) === value ? number : null;
        };
        const object = v => v !== null && typeof v === 'object' && !Array.isArray(v);
        if (!positive(issue) || !/^[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+$/.test(repository) || !outputPath)
          throw new Error('Invalid trusted gate context');
        const report = { version: 1, proof_origin: 'on_demand', authorization_only: true, proposed_pr: null, in_initial_index: null,
          fresh_status: 'unknown', fresh_reason: null, release_tag: null, requested: [], authorized: [], blocked: [], reasons: [] };
        const block = reason => { if (!report.reasons.includes(reason)) report.reasons.push(reason); };
        function readFile(file) {
          try {
            if (!fs.lstatSync(file).isFile()) return null;
            return fs.readFileSync(file);
          } catch (error) {
            if (['ENOENT', 'ENOTDIR', 'EACCES'].includes(error.code)) return null;
            throw error;
          }
        }
        function parse(bytes) {
          if (bytes === null) return null;
          try { return JSON.parse(bytes.toString('utf8')); }
          catch (error) { if (error instanceof SyntaxError) return null; throw error; }
        }
        const original = parse(readFile(outputPath));
        const envelope = object(original) ? original : {};
        const items = Array.isArray(envelope.items) ? envelope.items : [];
        // Quarantine all requests before loading optional runtime code or doing
        // proof work. An unexpected failure both fails this step (blocking native
        // dispatch) and leaves no original unsafe request file to replay.
        const quarantine = outputPath + '.triage-quarantine';
        fs.writeFileSync(quarantine, JSON.stringify({ ...envelope, items: [] }));
        fs.renameSync(quarantine, outputPath);
        const { normalizeIssueIntentLabelInputs } = require(path.join(runtimeDirectory, 'issue_intents.cjs'));
        const { validateLabels } = require(path.join(runtimeDirectory, 'safe_output_validator.cjs'));
        let protocolViolation = !object(original) || !Array.isArray(envelope.items);
        if (protocolViolation) block('invalid_output_envelope');
        // Preserve ingestion errors and every envelope field; never erase taint or
        // temporary-ID maps to make a rejected decision look high-integrity.
        if (envelope.errors !== undefined && (!Array.isArray(envelope.errors) || envelope.errors.length > 0)) {
          protocolViolation = true; block('ingestion_errors');
        }
        const fixedFiles = ['repo-labels.json', 'issue-number.txt', 'issue-type.txt', 'issue-state-history.json', 'pr-candidate-status.json', 'pr-candidate-screening-index.json', 'issue-candidate-index.json', 'triage-audit-block.md', 'triage-screening-status.md', 'pr-evidence-validation.json', 'release-status.json', 'triage-release-proof.sh'];
        const hash = bytes => crypto.createHash('sha256').update(bytes).digest('hex');
        const manifestBytes = readFile(path.join(evidenceDirectory, 'triage-evidence-manifest.json'));
        const manifest = parse(manifestBytes);
        const evidence = {};
        const producerAttempt = process.env.TRIAGE_PRODUCER_ATTEMPT;
        const consumerAttempt = process.env.GITHUB_RUN_ATTEMPT;
        const validAttempt = value => /^[1-9][0-9]*$/.test(value || '') && positive(Number(value));
        let trusted = /^[1-9][0-9]*$/.test(process.env.TRIAGE_ARTIFACT_ID || '') &&
          /^[a-f0-9]{64}$/.test(process.env.TRIAGE_MANIFEST_SHA256 || '') && manifestBytes !== null &&
          hash(manifestBytes) === process.env.TRIAGE_MANIFEST_SHA256 && object(manifest) &&
          manifest.version === 1 && manifest.repository === repository && manifest.issue_number === String(issue) &&
          manifest.run_id === process.env.GITHUB_RUN_ID && validAttempt(producerAttempt) && validAttempt(consumerAttempt) &&
          manifest.run_attempt === producerAttempt && Number(consumerAttempt) >= Number(producerAttempt) &&
          manifest.workflow_sha === process.env.TRIAGE_WORKFLOW_SHA && typeof manifest.default_branch === 'string' &&
          manifest.default_branch.length > 0 && object(manifest.files) &&
          Object.keys(manifest.files).length === fixedFiles.length;
        if (trusted) {
          for (const name of fixedFiles) {
            const bytes = readFile(path.join(evidenceDirectory, name));
            if (bytes === null || hash(bytes) !== manifest.files[name]) { trusted = false; break; }
            evidence[name] = bytes;
          }
        }
        if (trusted && evidence['issue-number.txt'].toString('utf8').trim() !== String(issue)) trusted = false;
        if (!trusted) block('trusted_evidence_unavailable');
        const json = name => trusted ? parse(evidence[name]) : null;
        const status = json('pr-candidate-status.json');
        const index = json('pr-candidate-screening-index.json');
        const validation = json('pr-evidence-validation.json');
        const history = json('issue-state-history.json');
        const duplicateIndex = json('issue-candidate-index.json');
        const numbers = a => Array.isArray(a) && a.every(positive) && new Set(a).size === a.length;
        const initial = object(index) && Array.isArray(index.required_inspection) && Array.isArray(index.open_inventory_screening)
          ? [...index.required_inspection, ...index.open_inventory_screening] : [];
        const contracts = trusted && validation?.valid === true && [status, index].every(v =>
          object(v) && v.loaded === true && v.complete === true && v.success === true && Array.isArray(v.errors) && v.errors.length === 0) &&
          index.version === 1 && status.index_version === 1 && numbers(initial.map(p => p?.number)) &&
          status.candidate_count === initial.length && index.candidate_count === initial.length;
        const historyLoaded = trusted && history?.loaded === true && Array.isArray(history.events) &&
          history.events.every(e => object(e) && ['closed', 'reopened'].includes(e.event) &&
            typeof e.created_at === 'string' && object(e.actor) && typeof e.actor.type === 'string' && typeof e.actor.login === 'string');
        const duplicateEvidence = trusted && duplicateIndex?.version === 1 && duplicateIndex.loaded === true &&
          duplicateIndex.complete === true && duplicateIndex.success === true && Array.isArray(duplicateIndex.errors) &&
          duplicateIndex.errors.length === 0 && evidence['triage-audit-block.md'].toString('utf8').startsWith('- Prefetched duplicate searches (from `issue-candidate-index.json`):');
        const targetKeys = ['item_number', 'issue_number', 'pr_number', 'pr-number', 'pull_number', 'pull_request_number', 'number'];
        const routingKeys = ['comment_id', 'commentId', 'comment-id', 'reply_to_id', 'target', 'discussion_number', 'discussion_id', 'pull_request_review_id', 'review_id'];
        function target(item, key, expected = issue) {
          return targetNumber(item[key]) === expected && targetKeys.every(k => item[k] === undefined || targetNumber(item[k]) === expected) &&
            routingKeys.every(k => item[k] === undefined) &&
            (item.repo === undefined || item.repo === repository) &&
            (item.repository === undefined || item.repository === repository);
        }
        const comments = items.filter(i => object(i) && i.type === 'add_comment');
        const comment = comments.length === 1 && target(comments[0], 'item_number') ? comments[0] : null;
        const fields = ['version', 'fixing_pr', 'fix_confidence', 'release_action', 'human_reopen_override', 'screening_complete', 'fully_inspected_prs', 'screened_inventory_prs', 'findings', 'audit'];
        const data = comment?.data;
        const validData = object(data) && Object.keys(data).length === fields.length && fields.every(k => Object.hasOwn(data, k)) &&
          data.version === 1 && Number.isSafeInteger(data.fixing_pr) && data.fixing_pr >= 0 &&
          ['none', 'confirmed', 'related', 'partial'].includes(data.fix_confidence) && ['none', 'evaluate_fix'].includes(data.release_action) &&
          typeof data.human_reopen_override === 'boolean' && typeof data.screening_complete === 'boolean' &&
          numbers(data.fully_inspected_prs) && numbers(data.screened_inventory_prs) &&
          data.fully_inspected_prs.length <= 10000 && data.screened_inventory_prs.length <= 10000 &&
          typeof data.findings === 'string' && data.findings.length <= 12000 && typeof data.audit === 'string' && data.audit.length <= 20000;
        if (!validData) block('missing_or_invalid_decision');
        if (comments.length > 1 || items.some(i => object(i) && i.type !== 'add_comment' && i.data !== undefined)) {
          protocolViolation = true; block('multiple_or_misplaced_decisions');
        }
        const wantsRelease = validData && data.release_action === 'evaluate_fix';
        if (validData) {
          report.proposed_pr = data.fixing_pr || null;
          report.in_initial_index = trusted ? initial.some(p => p.number === data.fixing_pr) : null;
        }
        if (wantsRelease) report.requested.push('evaluate_fix');
        report.missing_full_inspection = contracts && validData ? initial
          .filter(p => index.required_inspection.includes(p) || p.lexical_relevance?.plausible === true)
          .map(p => p.number).filter(n => !data.fully_inspected_prs.includes(n)) : null;
        report.missing_inventory_screening = contracts && validData ? initial
          .filter(p => p.open_inventory || p.merged_inventory)
          .map(p => p.number).filter(n => !data.screened_inventory_prs.includes(n)) : null;
        const coverage = contracts && validData && data.screening_complete &&
          report.missing_full_inspection.length === 0 && report.missing_inventory_screening.length === 0;
        // An explicit human-reopen veto can only restrict actions, so retain it
        // even when another field made that comment's decision invalid.
        const humanVeto = comments.some(i => i.data?.human_reopen_override === true);
        // Without a structured finding, an ambiguous bot-close/human-reopen
        // history cannot be used to approve even the independent duplicate route.
        let botClosed = false;
        const ambiguousReopen = historyLoaded && history.events.some(e => {
          if (e.event === 'closed' && e.actor.type === 'Bot') botClosed = true;
          return botClosed && e.event === 'reopened' && e.actor.type === 'User';
        });
        const closureVeto = !historyLoaded || humanVeto || (!validData && ambiguousReopen);
        if (!historyLoaded) block('history_unavailable');
        if (humanVeto || (!validData && ambiguousReopen)) block('human_reopen_override');
        const fixed = 'Status: Fixed :white_check_mark:';
        const awaiting = 'Status: Awaiting Release To Be Cut :scissors:';
        const reserved = new Set([fixed.toLowerCase(), awaiting.toLowerCase()]);
        const definitions = json('repo-labels.json');
        const labels = Array.isArray(definitions) ? definitions.filter(l => object(l) && typeof l.name === 'string').map(l => l.name) : [];
        function effectiveLabel(label) {
          // Match both native object-name sanitization and the validator's second
          // sanitization/64-character limit. Merely trim/lowercase is insufficient.
          try {
            // Rationale/confidence do not change the effective label name. Do
            // not let malformed metadata hide a raw reserved-name attempt.
            const nameOnly = object(label) ? { name: label.name } : label;
            const input = normalizeIssueIntentLabelInputs([nameOnly]).map(l => typeof l === 'string' ? l : l.name);
            const result = validateLabels(input, undefined, 10);
            return result.valid && result.value.length === 1 ? result.value[0] : null;
          } catch (error) {
            if (error instanceof Error && error.message.startsWith('Invalid labels')) return null;
            if (error instanceof Error && error.message.startsWith('Label removal')) return null;
            throw error;
          }
        }
        const approved = [];
        const duplicates = [];
        const prMetadataKeys = ['temporary_id', 'tainted', 'taint', 'integrity'];
        const prAppendKeys = new Set(['type', 'pull_request_number', 'operation', 'body', 'repo', 'repository', ...targetKeys, ...prMetadataKeys]);
        let typeCount = 0, labelCount = 0, prCount = 0;
        for (const item of items) {
          if (!object(item)) { protocolViolation = true; block('invalid_item'); continue; }
          if (item.type === 'add_comment') continue;
          if (item.type === 'close_issue') {
            report.requested.push('close_issue');
            if (item.state_reason !== 'duplicate') {
              protocolViolation = true; block('raw_completion_or_invalid_reason'); report.blocked.push('close_issue'); continue;
            }
            if (!target(item, 'issue_number') || !positive(item.duplicate_of) || item.duplicate_of === issue) {
              protocolViolation = true; block('invalid_duplicate_target'); report.blocked.push('close_issue'); continue;
            }
            duplicates.push(item);
          } else if (item.type === 'add_labels') {
            if (!Array.isArray(item.labels)) { protocolViolation = true; block('invalid_labels'); continue; }
            const kept = [];
            for (const label of item.labels) {
              const name = effectiveLabel(label);
              if (name && reserved.has(name.toLowerCase())) {
                protocolViolation = true; block('raw_release_label'); report.blocked.push(name);
              } else if (name && labels.some(l => l.toLowerCase() === name.toLowerCase())) kept.push(label);
              else block('label_not_defined');
            }
            if (!target(item, 'item_number')) { protocolViolation = true; block('invalid_target'); continue; }
            if (kept.length && labelCount++ < 10) approved.push({ ...item, labels: kept });
          } else if (item.type === 'set_issue_type') {
            if (target(item, 'issue_number') && ['Bug', 'Feature', 'Task'].includes(item.issue_type) && typeCount++ < 1) approved.push(item);
            else { protocolViolation = true; block('invalid_type_or_target'); }
          } else if (item.type === 'update_pull_request') {
            // Native handlers accept extra mutation fields despite append-only configuration. Reject extras and rebuild the request rather than forwarding it.
            if (Object.keys(item).some(key => !prAppendKeys.has(key))) {
              block('pr_append_extra_fields'); report.blocked.push('update_pull_request'); continue;
            }
            const prNumber = targetNumber(item.pull_request_number);
            if (coverage && positive(prNumber) && target(item, 'pull_request_number', prNumber) &&
                item.operation === 'append' && item.body === `Fixes #${issue}` && validData &&
                data.fix_confidence === 'confirmed' && data.fixing_pr === prNumber &&
                data.fully_inspected_prs.includes(prNumber) && prCount++ < 1) {
              const metadata = Object.fromEntries(prMetadataKeys.filter(key => Object.hasOwn(item, key)).map(key => [key, item[key]]));
              approved.push({ ...metadata, type: 'update_pull_request', repo: repository,
                pull_request_number: prNumber, operation: 'append', body: `Fixes #${issue}` });
            }
            else { block('pr_link_veto'); report.blocked.push('update_pull_request'); }
          } else {
            // No alternative close/update/custom path may reach native dispatch.
            protocolViolation = true; block('unsupported_output'); report.blocked.push(String(item.type));
          }
        }
        if (duplicates.length > 1 || (duplicates.length && wantsRelease)) {
          protocolViolation = true; block('conflicting_dispositions');
        }
        if (duplicates.length && !duplicateEvidence) block('duplicate_evidence_unavailable');
        if (duplicates.length === 1 && !closureVeto && !protocolViolation && duplicateEvidence) {
          const item = duplicates[0];
          approved.push({ ...item, body: `Duplicate of #${item.duplicate_of}` });
        } else if (duplicates.length) report.blocked.push('duplicate_closure');
        // Write an honest final-proof artifact even when no lookup can be admitted.
        let proof = { version: 1, loaded: false, has_release: null, latest_tag: null, latest_published_at: null,
          reason: 'not_requested_or_vetoed', prs: [] };
        fs.writeFileSync(proofPath, JSON.stringify(proof));
        const selected = wantsRelease && positive(data.fixing_pr) && data.fix_confidence === 'confirmed' &&
          data.fully_inspected_prs.includes(data.fixing_pr);
        if (wantsRelease && !selected) block('invalid_fix_selection');
        if (wantsRelease && !coverage) block('incomplete_collection_or_screening');
        if (selected && coverage && !protocolViolation && !closureVeto) {
          // Fixed executable and argument vector; no model text becomes shell source.
          try {
            execFileSync('/bin/bash', [path.join(evidenceDirectory, 'triage-release-proof.sh'), 'selected',
              evidenceDirectory, proofPath, String(data.fixing_pr)], {
              env: { ...process.env, GH_AW_GITHUB_REPOSITORY: repository, DEFAULT_BRANCH: manifest.default_branch },
              timeout: 205000, maxBuffer: 4 * 1024 * 1024, stdio: ['ignore', 'pipe', 'pipe']
            });
          } catch (error) {
            if (!Number.isInteger(error.status) && error.code !== 'ETIMEDOUT' && error.code !== 'ENOENT') throw error;
            block('selected_verifier_failed');
            fs.writeFileSync(proofPath, JSON.stringify({ ...proof, reason: 'selected_verifier_failed' }));
          }
          proof = parse(readFile(proofPath));
          const entry = object(proof) && proof.version === 1 && proof.loaded === true && proof.has_release === true &&
            Array.isArray(proof.prs) && proof.prs.length === 1 && proof.prs[0]?.number === data.fixing_pr ? proof.prs[0] : null;
          if (entry && ['released', 'awaiting_release', 'unknown'].includes(entry.status) && typeof entry.reason === 'string') {
            report.fresh_status = entry.status;
            report.fresh_reason = entry.reason;
            if (entry.status === 'released' && typeof entry.release_tag === 'string' && /^[^\s]+$/.test(entry.release_tag)) {
              report.release_tag = entry.release_tag;
              // Carry the decision's integrity metadata, not its comment target,
              // data, temporary ID, or agent-written action body into generated items.
              const metadata = { ...comment };
              for (const key of [...targetKeys, ...routingKeys, 'type', 'body', 'data', 'temporary_id', 'labels', 'state_reason', 'duplicate_of']) delete metadata[key];
              if (labels.includes(fixed)) {
                approved.push({ ...metadata, type: 'close_issue', issue_number: issue, state_reason: 'completed',
                  body: `Fixed by PR #${data.fixing_pr}. Released in ${entry.release_tag}.\n\nIf this is still happening on ${entry.release_tag} or later, please reopen with your module version and a configuration snippet.` });
                approved.push({ ...metadata, type: 'add_labels', item_number: issue, labels: [fixed] });
              } else block('fixed_label_not_defined');
            } else if (entry.status === 'awaiting_release' && entry.release_tag === null) {
              if (labels.includes(awaiting)) {
                const metadata = { ...comment };
                for (const key of [...targetKeys, ...routingKeys, 'type', 'body', 'data', 'temporary_id', 'labels', 'state_reason', 'duplicate_of']) delete metadata[key];
                approved.push({ ...metadata, type: 'add_labels', item_number: issue, labels: [awaiting] });
              } else block('awaiting_label_not_defined');
            } else { report.fresh_status = 'unknown'; block('release_membership_unverified'); }
          } else { report.fresh_status = 'unknown'; block('invalid_or_missing_selected_proof'); }
        }
        // Prioritize a synthesized release label within the existing native
        // ten-batch limit; never increase the limit or combine items' taint.
        const generatedLabel = approved.findIndex(i => i.type === 'add_labels' && i.labels.some(l => [fixed, awaiting].includes(l)));
        if (generatedLabel >= 0) approved.unshift(...approved.splice(generatedLabel, 1));
        let retainedLabels = 0;
        for (let i = 0; i < approved.length; i++) {
          if (approved[i].type === 'add_labels' && ++retainedLabels > 10) {
            approved.splice(i--, 1); block('native_label_batch_limit');
          }
        }
        // Missing/malformed helper output still leaves an independently uploaded
        // final proof artifact, explicitly unknown rather than an absent file.
        if (!object(proof)) {
          proof = { version: 1, loaded: false, has_release: null, latest_tag: null, latest_published_at: null,
            reason: 'invalid_or_missing_selected_proof', prs: [] };
          fs.writeFileSync(proofPath, JSON.stringify(proof));
        }
        report.authorized = approved.map(i => i.type === 'close_issue' ? `close_issue:${i.state_reason}` :
          i.type === 'add_labels' ? `add_labels:${i.labels.map(effectiveLabel).join(', ')}` : i.type);
        if (wantsRelease && !approved.some(i => i.type === 'close_issue' && i.state_reason === 'completed')) report.blocked.push('completed_closure');
        const actionLines = [];
        if (report.release_tag) actionLines.push(`Trusted release verification found PR #${report.proposed_pr} in release ${report.release_tag}.`);
        else if (report.fresh_status === 'awaiting_release') actionLines.push(`Trusted release verification found PR #${report.proposed_pr} on the default branch. Every published stable release precedes its merge result; no published stable release contains it. Awaiting-release labeling is authorized only as listed below.`);
        else if (wantsRelease) actionLines.push(`Release membership for PR #${report.proposed_pr || '(invalid selection)'} could not be verified. This run does not authorize completed closure or either release label; absence from the initial list is not evidence of an unreleased fix.`);
        if (!validData) actionLines.push('The mandatory structured triage decision was missing or invalid. The original comment body is not an authorization record and was not published.');
        actionLines.push(`Requested: ${report.requested.join(', ') || 'no release or closure request'}.`);
        actionLines.push(`Authorized native requests: ${report.authorized.join('; ') || 'none'}.`);
        if (report.reasons.length) actionLines.push(`Blocked or unavailable: ${report.reasons.join(', ')}.`);
        if (report.missing_full_inspection?.length) actionLines.push(`Missing declared full inspections: ${report.missing_full_inspection.join(', ')}.`);
        if (report.missing_inventory_screening?.length) actionLines.push(`Missing declared inventory screening: ${report.missing_inventory_screening.join(', ')}.`);
        if (!approved.some(i => i.type === 'close_issue')) actionLines.push('No automated closure is authorized; the issue is to remain open for review.');
        actionLines.push('Authorization is not execution: native handlers run next, and comment, label, type, PR-link and close operations are not atomic. Their results record what GitHub accepted.');
        // Deliberately never reuse or regex-edit the agent's old free-form body.
        const semantic = validData ? `\n### Agent semantic findings (not an execution record)\n\n${data.findings}\n` : '';
        const audit = trusted ? evidence['triage-audit-block.md'].toString('utf8') + '\n' + evidence['triage-screening-status.md'].toString('utf8') : 'Trusted evidence snapshot unavailable.';
        const duplicateNote = approved.some(i => i.type === 'close_issue' && i.state_reason === 'duplicate') ?
          '\n> **Note:** If you believe this issue was incorrectly closed as a duplicate, please reopen it and explain how it differs from the linked issue.\n' : '';
        const body = '## 🤖 GitHub Agentic Workflow Automated Triage 🤖\n\n> ⚠️ _This triage was generated automatically by an AI agent and may be incomplete or inaccurate._\n\n' +
          actionLines.map(l => '- ' + l).join('\n') + '\n' + semantic + duplicateNote +
          '\n<details>\n<summary><b>🔎 What this triage looked at</b></summary>\n\n' + audit +
          (validData ? `\nAgent-reported sources and verdicts:\n${data.audit}\n\nDeclared fully inspected PRs: ${data.fully_inspected_prs.join(', ') || 'none'}.\nDeclared screened inventory PRs: ${data.screened_inventory_prs.join(', ') || 'none'}.\n` : '\n') + '\n</details>';
        const rendered = { ...(comment || comments[0] || {}), type: 'add_comment', item_number: issue, body };
        for (const key of [...targetKeys.filter(k => k !== 'item_number'), ...routingKeys, 'repo', 'repository']) delete rendered[key];
        // Fallback comments retain a valid original item's taint and temporary ID.
        // A generated comment never clears envelope-level integrity information.
        fs.writeFileSync(path.join(directory, 'triage-gate-report.json'), JSON.stringify(report, null, 2));
        const replacement = { ...envelope, items: [rendered, ...approved] };
        const temporary = outputPath + '.triage-gated';
        fs.writeFileSync(temporary, JSON.stringify(replacement));
        fs.renameSync(temporary, outputPath);
  - name: Upload triage gate authorization report
    uses: actions/upload-artifact@043fb46d1a93c77aae656e7c1c64a875d1fc6a0a
    with:
      name: triage-gate-report-${{ github.run_id }}-${{ github.run_attempt }}
      path: |
        ${{ steps.triage-gate-directory.outputs.path }}/triage-gate-report.json
        ${{ steps.triage-gate-directory.outputs.path }}/selected-pr-release-status.json
      if-no-files-found: error
      overwrite: false
  add-comment:
    max: 1
    target: "*"
    hide-older-comments: true
  add-labels:
    max: 10
    target: "*"
    # Opt out of issue-intent metadata (ADR-46207 flipped this default to on).
    # When enabled, labels are sent via the GraphQL `update_issue_suggestions`
    # path, where GitHub records anything below HIGH confidence as a suggestion
    # instead of applying it — while gh-aw still logs "Successfully added N
    # labels". Forcing the REST path applies every label the agent selects.
    issue-intent: false
  set-issue-type:
    allowed:
    - Bug
    - Feature
    - Task
    max: 1
    target: "*"
    issue-intent: false
  close-issue:
    max: 1
    target: "*"
    # List form lets the agent pick the reason per closure. A scalar would lock
    # every closure to one reason, which recorded fix-confirmed closures as
    # "duplicate". The first entry is the fallback when the agent omits one.
    state-reason:
    - duplicate
    - completed
  update-pull-request:
    title: false
    body: true
    operation: append
    footer: false
    max: 1
    target: "*"
  threat-detection:
    # Same workaround as the agent job below; custom `steps:` only inject into
    # the agent job, so the detection job needs its own copy. A failed detection
    # install yields conclusion=warning, which blocks every non-reviewable safe
    # output (add-labels, set-issue-type, close-issue) under policy WTD3.
    steps:
    - name: Force Copilot CLI download (workaround github/gh-aw#52327)
      run: sudo rm -rf /opt/hostedtoolcache/copilot-cli || true
jobs:
  triage_evidence:
    runs-on: ubuntu-latest
    outputs:
      artifact_id: ${{ steps.upload-triage-evidence.outputs.artifact-id }}
      manifest_sha256: ${{ steps.seal-triage-evidence.outputs.sha256 }}
      producer_attempt: ${{ steps.seal-triage-evidence.outputs.producer_attempt }}
    permissions:
      contents: read
      issues: read
      pull-requests: read
    steps:
    - name: Fetch label definitions
      env:
        GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}
        GH_AW_GITHUB_REPOSITORY: ${{ github.repository }}
      run: |
        mkdir -p /tmp/gh-aw/agent
        LABELS_FILE=/tmp/gh-aw/agent/repo-labels.json
        gh api "repos/${GH_AW_GITHUB_REPOSITORY}/labels?per_page=100" | jq '[.[] | {name, description}]' > "$LABELS_FILE" || echo '[]' > "$LABELS_FILE"
    - name: Resolve target issue number
      env:
        ISSUE_NUMBER: ${{ github.event.inputs.issue_number || github.event.issue.number }}
      run: |
        echo "${ISSUE_NUMBER}" > /tmp/gh-aw/agent/issue-number.txt
    - name: Fetch current issue type
      env:
        GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}
        GH_AW_GITHUB_REPOSITORY: ${{ github.repository }}
        ISSUE_NUMBER: ${{ github.event.inputs.issue_number || github.event.issue.number }}
      run: |
        set -o pipefail
        TYPE_FILE=/tmp/gh-aw/agent/issue-type.txt
        RAW=$(mktemp)
        # The agent's issue-reading tool does not return the native issue type, and
        # the `Type: …` labels and the template's "### Issue Type?" field are not it.
        if gh api "repos/${GH_AW_GITHUB_REPOSITORY}/issues/${ISSUE_NUMBER}" \
          --jq '.type.name // "NONE"' > "${RAW}"; then
          tr -d '\r' < "${RAW}" | head -n 1 > "${TYPE_FILE}"
        else
          echo "UNKNOWN" > "${TYPE_FILE}"
        fi
        rm -f "${RAW}"
    - name: Fetch issue close and reopen history
      env:
        GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}
        GH_AW_GITHUB_REPOSITORY: ${{ github.repository }}
        ISSUE_NUMBER: ${{ github.event.inputs.issue_number || github.event.issue.number }}
      run: |
        set -o pipefail
        HISTORY_FILE=/tmp/gh-aw/agent/issue-state-history.json
        EVENTS_FILE=$(mktemp)
        if gh api --paginate "repos/${GH_AW_GITHUB_REPOSITORY}/issues/${ISSUE_NUMBER}/events?per_page=100" \
          | jq -s '[.[][] | select(.event == "closed" or .event == "reopened") | {
              event,
              created_at,
              actor: {
                login: .actor.login,
                type: .actor.type
              }
            }]' > "${EVENTS_FILE}"; then
          jq -n --slurpfile events "${EVENTS_FILE}" '{loaded: true, events: $events[0]}' > "${HISTORY_FILE}"
        else
          echo '{"loaded":false,"events":[]}' > "${HISTORY_FILE}"
        fi
        rm -f "${EVENTS_FILE}"
    - name: Prefetch PR candidate evidence for target issue
      env:
        GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}
        GH_AW_GITHUB_REPOSITORY: ${{ github.repository }}
        ISSUE_NUMBER: ${{ github.event.inputs.issue_number || github.event.issue.number }}
      run: |
        set -o pipefail
        mkdir -p /tmp/gh-aw/agent
        STATUS_FILE=/tmp/gh-aw/agent/pr-candidate-status.json
        INDEX_FILE=/tmp/gh-aw/agent/pr-candidate-screening-index.json
        INDEX_VERSION=1
        REPO="${GH_AW_GITHUB_REPOSITORY}"
        NUM="${ISSUE_NUMBER}"
        write_failure_contracts() {
          FAILURE_MESSAGE="$1"
          jq -n --arg issue "${NUM}" --arg repo "${REPO}" --arg error "${FAILURE_MESSAGE}" --argjson version "${INDEX_VERSION}" \
            '{
              version:$version,
              issue_number:($issue | tonumber? // $issue),
              repository:$repo,
              loaded:false,
              complete:false,
              success:false,
              errors:[$error],
              candidate_count:0,
              required_inspection:[],
              open_inventory_screening:[]
            }' > "${INDEX_FILE}"
          jq -n \
            --arg issue "${NUM}" \
            --arg repo "${REPO}" \
            --arg error "${FAILURE_MESSAGE}" \
            --arg index_path "${INDEX_FILE}" \
            --argjson index_version "${INDEX_VERSION}" \
            '{
              issue_number:($issue | tonumber? // $issue),
              repository:$repo,
              loaded:false,
              complete:false,
              success:false,
              errors:[$error],
              candidate_count:0,
              open_inventory_count:0,
              merged_inventory_count:0,
              required_inspection_count:0,
              required_inspection_numbers:[],
              exact_required_inspection_count:0,
              exact_required_inspection_numbers:[],
              timeline_required_inspection_count:0,
              timeline_required_inspection_numbers:[],
              commit_required_inspection_count:0,
              commit_required_inspection_numbers:[],
              screening_index_path:$index_path,
              index_version:$index_version
            }' > "${STATUS_FILE}"
        }
        if ! printf '%s' "${REPO}" | grep -Eq '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$' \
          || ! printf '%s' "${NUM}" | grep -Eq '^[1-9][0-9]*$'; then
          write_failure_contracts "invalid repository or issue number"
          exit 0
        fi
        WORK_DIR=$(mktemp -d)
        CANDIDATES_JSONL="${WORK_DIR}/candidates.jsonl"
        ERRORS_FILE="${WORK_DIR}/errors.txt"
        : > "${CANDIDATES_JSONL}"
        : > "${ERRORS_FILE}"
        COMPLETE=true
        # Conservative fallback written up front: if this step dies before the final
        # write below, the agent still finds an honest "incomplete" file rather than a
        # stale or missing one, so it never treats a failed load as a false success.
        write_failure_contracts "prefetch step did not finish"
        record_error() {
          echo "$1" >> "${ERRORS_FILE}"
          COMPLETE=false
        }
        ISSUE_RAW="${WORK_DIR}/issue.json"
        if ! gh api "repos/${REPO}/issues/${NUM}" > "${ISSUE_RAW}" 2>>"${ERRORS_FILE}"; then
          echo '{"title":"","body":""}' > "${ISSUE_RAW}"
          record_error "issue metadata: gh api fetch failed for issue #${NUM}"
        fi
        # Source 1: issue timeline - cross-referenced PRs, including non-closing mentions.
        TIMELINE_RAW="${WORK_DIR}/timeline.jsonl"
        if gh api --paginate "repos/${REPO}/issues/${NUM}/timeline?per_page=100" > "${TIMELINE_RAW}" 2>>"${ERRORS_FILE}"; then
          jq -c -s --arg repo "${REPO}" '
            add // []
            | .[]
            | select(.event == "cross-referenced")
            | (.source.issue? // empty)
            | select(.repository_url == ("https://api.github.com/repos/" + $repo))
            | select(.pull_request != null)
            | {
                number: .number,
                title: .title,
                url: .html_url,
                state: (.state // "unknown" | ascii_upcase),
                draft: (.draft // false),
                merged: (.pull_request.merged_at != null),
                body: (.body // ""),
                source: "timeline_cross_reference",
                detail: "Timeline cross-reference on the issue (includes non-closing mentions)"
              }
          ' "${TIMELINE_RAW}" >> "${CANDIDATES_JSONL}" 2>>"${ERRORS_FILE}" || record_error "timeline: jq processing failed for issue #${NUM}"
        else
          record_error "timeline: gh api fetch failed for issue #${NUM}"
        fi
        # Sources 2-4: an exhaustive, paginated PR scan. It provides exact title/body
        # matches and commit references across every PR state, plus a compact inventory
        # of every currently open PR so reference-free fixes remain discoverable.
        GRAPHQL_QUERY="${WORK_DIR}/pr-scan.graphql"
        cat > "${GRAPHQL_QUERY}" <<'GRAPHQL_EOF'
        query($owner: String!, $repo: String!, $endCursor: String) {
          repository(owner: $owner, name: $repo) {
            pullRequests(first: 50, after: $endCursor, states: [OPEN, CLOSED, MERGED], orderBy: {field: UPDATED_AT, direction: DESC}) {
              pageInfo { hasNextPage endCursor }
              nodes {
                number
                title
                url
                state
                isDraft
                merged
                body
                commits(first: 100) {
                  pageInfo { hasNextPage }
                  nodes { commit { oid message } }
                }
                files(first: 30) {
                  pageInfo { hasNextPage }
                  nodes { path }
                }
                mergedAt
              }
            }
          }
        }
        GRAPHQL_EOF
        OWNER_NAME="${REPO%%/*}"
        REPO_NAME="${REPO##*/}"
        PR_SCAN_RAW="${WORK_DIR}/pr-scan.jsonl"
        # Recently merged PRs are inventoried alongside open ones so an issue that was
        # already fixed on the default branch can be recognised even when nothing in
        # the issue references the fixing PR. Bounded by age and count to keep the
        # candidate set reviewable on long-lived repositories.
        MERGED_CUTOFF="$(date -u -d '180 days ago' '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || echo '1970-01-01T00:00:00Z')"
        if gh api graphql --paginate -F query="@${GRAPHQL_QUERY}" -f owner="${OWNER_NAME}" -f repo="${REPO_NAME}" > "${PR_SCAN_RAW}" 2>>"${ERRORS_FILE}"; then
          jq -c -s --arg num "${NUM}" --arg repo "${REPO}" --arg cutoff "${MERGED_CUTOFF}" '
            ("#" + $num + "\\b") as $numRef
            | ($repo + "#" + $num + "\\b") as $qualRef
            | ("(?i)\\b(refs?|fixes?|closes?|resolves?)\\b[[:space:]]*#" + $num + "\\b") as $bodyRef
            | [.[].data.repository.pullRequests.nodes[]?] as $prs
            | (
                [$prs[] | select((.merged == true) and ((.mergedAt // "") >= $cutoff))]
                | sort_by(.mergedAt) | reverse | .[0:25]
                | .[]
                | {number:.number, title:.title, url:.url, state:.state, draft:.isDraft, merged:.merged, body:(.body // ""),
                   source:"merged_pr_inventory", detail:"Recently merged PR; screen for a fix that already shipped on the default branch",
                   file_names:[.files.nodes[]?.path], files_truncated:(.files.pageInfo.hasNextPage // false)}
              ),
              (
              $prs[]
            | . as $pr
            | (
                (if $pr.state == "OPEN" then
                  [{number:$pr.number, title:$pr.title, url:$pr.url, state:$pr.state, draft:$pr.isDraft, merged:$pr.merged, body:($pr.body // ""),
                    source:"open_pr_inventory", detail:"Current open PR; screen title, body excerpt, and changed-file names for relevance",
                    file_names:[$pr.files.nodes[]?.path], files_truncated:($pr.files.pageInfo.hasNextPage // false)}]
                else [] end)
                +
                (if (($pr.title // "") | test($numRef) or (($pr.title // "") | test($qualRef))) then
                  [{number:$pr.number, title:$pr.title, url:$pr.url, state:$pr.state, draft:$pr.isDraft, merged:$pr.merged, body:($pr.body // ""), source:"issue_number_search_title", detail:("PR title contains #" + $num + " or a repo-qualified reference")}]
                else [] end)
                +
                (if (($pr.body // "") | test($numRef) or (($pr.body // "") | test($qualRef))) then
                  [{number:$pr.number, title:$pr.title, url:$pr.url, state:$pr.state, draft:$pr.isDraft, merged:$pr.merged, body:($pr.body // ""), source:"issue_number_search_body", detail:("PR body contains #" + $num + " or a repo-qualified reference")}]
                else [] end)
                +
                [
                  ($pr.commits.nodes[]? | .commit
                   | select((.message | test($numRef)) or (.message | test($qualRef)))
                   | {
                       number: $pr.number, title: $pr.title, url: $pr.url, state: $pr.state, draft: $pr.isDraft, merged: $pr.merged, body: ($pr.body // ""),
                       source: (if (.message | test($bodyRef)) then "commit_body_refs" else "commit_message_reference" end),
                       sha: .oid, message: .message,
                       detail: ("Commit message references #" + $num)
                     }
                  )
                ]
              )
              | .[]
              )
          ' "${PR_SCAN_RAW}" >> "${CANDIDATES_JSONL}" 2>>"${ERRORS_FILE}" || record_error "graphql pr scan: jq processing failed for issue #${NUM}"
          TRUNCATED_COMMITS=$(jq -s '[.[].data.repository.pullRequests.nodes[]? | select(.commits.pageInfo.hasNextPage == true)] | length' "${PR_SCAN_RAW}" 2>>"${ERRORS_FILE}") \
            || { TRUNCATED_COMMITS=1; record_error "graphql pr scan: jq commit-pagination check failed"; }
          if [ "${TRUNCATED_COMMITS}" -gt 0 ]; then
            record_error "graphql pr scan: ${TRUNCATED_COMMITS} PR(s) have more than 100 commits; commit-reference evidence is incomplete"
          fi
          LAST_HAS_NEXT=$(jq -s '[.[].data.repository.pullRequests.pageInfo.hasNextPage] | last // false' "${PR_SCAN_RAW}" 2>>"${ERRORS_FILE}")
          if [ "${LAST_HAS_NEXT}" = "true" ]; then
            record_error "graphql pr scan: pagination did not complete (hasNextPage still true) - results may be partial"
          fi
        else
          record_error "graphql pr scan: gh api graphql fetch failed for repo ${REPO}"
        fi
        # Source 3: exact issue-number search across PR comments (all states, no date limit).
        for VARIANT in "#${NUM}" "${REPO}#${NUM}"; do
          SAFE_NAME=$(echo "${VARIANT}" | tr -c 'a-zA-Z0-9' '_')
          COMMENT_SEARCH_RAW="${WORK_DIR}/comment-search-${SAFE_NAME}.jsonl"
          if gh api --paginate --method GET search/issues -f q="repo:${REPO} is:pr in:comments \"${VARIANT}\"" > "${COMMENT_SEARCH_RAW}" 2>>"${ERRORS_FILE}"; then
            jq -c -s '
              [.[] | (.items // [])[]?]
              | .[]
              | {
                  number: .number, title: .title, url: .html_url, state: (.state | ascii_upcase),
                  draft: (.draft // false), merged: (.pull_request.merged_at != null),
                  body: (.body // ""), source: "issue_number_search_comment",
                  detail: "Matched via GitHub search in a PR comment"
                }
            ' "${COMMENT_SEARCH_RAW}" >> "${CANDIDATES_JSONL}" 2>>"${ERRORS_FILE}" || record_error "comment search: jq processing failed for variant ${VARIANT}"
            SEARCH_TOTAL=$(jq -s '[.[].total_count // 0] | max // 0' "${COMMENT_SEARCH_RAW}" 2>>"${ERRORS_FILE}") \
              || { SEARCH_TOTAL=1; record_error "comment search: jq total-count check failed for variant ${VARIANT}"; }
            SEARCH_COLLECTED=$(jq -s '[.[] | (.items // []) | length] | add // 0' "${COMMENT_SEARCH_RAW}" 2>>"${ERRORS_FILE}") \
              || { SEARCH_COLLECTED=0; record_error "comment search: jq result-count check failed for variant ${VARIANT}"; }
            if [ "${SEARCH_TOTAL}" -gt "${SEARCH_COLLECTED}" ]; then
              record_error "comment search: GitHub search returned ${SEARCH_COLLECTED} of ${SEARCH_TOTAL} results for ${VARIANT} (1000-result cap or incomplete pagination)"
            fi
          else
            record_error "comment search: gh api search fetch failed for variant ${VARIANT}"
          fi
        done
        # Merge and de-dupe by PR number, preserving every source and its evidence so
        # Step 6 can report related/partial PRs even when they are not linked.
        if [ -s "${CANDIDATES_JSONL}" ]; then
          jq -c -s '
            group_by(.number)
            | map({
                number: .[0].number,
                title: (first(.[] | select(.title != null and .title != "") | .title) // .[0].title),
                url: (first(.[] | select(.url != null and .url != "") | .url) // .[0].url),
                state: (first(.[] | select(.state != null and .state != "") | .state) // .[0].state),
                draft: (any(.[]; .draft == true)),
                merged: (any(.[]; .merged == true)),
                body_excerpt: ((first(.[] | select(.body != null and .body != "") | .body) // "")[0:600]),
                sources: ([.[] | .source] | unique),
                file_names: ([.[] | .file_names[]?] | unique),
                files_truncated: (any(.[]; .files_truncated == true)),
                evidence: [.[] | {source, detail, sha, message} | with_entries(select(.value != null))]
              })
            | sort_by(.number)
          ' "${CANDIDATES_JSONL}" > "${WORK_DIR}/deduped.json" 2>>"${ERRORS_FILE}" || record_error "dedupe: jq processing failed"
        else
          echo '[]' > "${WORK_DIR}/deduped.json"
        fi
        if [ ! -s "${WORK_DIR}/deduped.json" ]; then
          echo '[]' > "${WORK_DIR}/deduped.json"
        fi
        CANDIDATE_COUNT=$(jq 'length' "${WORK_DIR}/deduped.json" 2>/dev/null || echo 0)
        # Build a compact index for inventory screening, bounded so the agent never
        # has to print a large file to enumerate candidates.
        jq -n \
          --arg issue "${NUM}" \
          --arg repo "${REPO}" \
          --argjson complete "${COMPLETE}" \
          --argjson version "${INDEX_VERSION}" \
          --slurpfile issue_data "${ISSUE_RAW}" \
          --slurpfile candidates "${WORK_DIR}/deduped.json" \
          --rawfile errorlog "${ERRORS_FILE}" \
          '
            def tokens:
              ascii_downcase
              | gsub("[^a-z0-9_]+"; " ")
              | split(" ")
              # Keep snake_case compounds whole and also emit their parts, so prose
              # terms ("role assignment") can match identifiers ("role_assignments").
              | map(. as $raw | [$raw] + (if ($raw | test("_")) then ($raw | split("_")) else [] end))
              | flatten
              | map(select(length >= 4))
              | map(
                  if test("^[a-z][a-z0-9_]*s$") and length > 4 and (endswith("ss") | not)
                  then .[0:-1]
                  else .
                  end
                )
              | . as $tokens
              | [
                  "about","above","across","after","again","against","already","also","although","always",
                  "among","another","appear","applied","apply","available","because","before","being","below",
                  "between","body","branch","change","changes","check","checked","clear","code","configuration",
                  "continue","correlation","could","current","default","description","details","during","each",
                  "error","example","existing","fails","from","github","have","having","include","issue","later",
                  "main","make","module","more","need","needed","other","passes","please","provider","request",
                  "resource","should","state","still","than","that","their","then","there","these","they","this",
                  "through","type","update","using","value","version","when","where","which","while","with","would"
                ] as $stop
              | $tokens
              | map(. as $token | select(($stop | index($token)) == null))
              | unique;
            def overlap($left; $right):
              [$left[] as $token | select(($right | index($token)) != null) | $token] | unique | sort;
            # Filenames that appear in nearly every AVM PR carry no discovery signal.
            def ubiquitous_file_tokens:
              [
                "changelog","example","footer","header","input","integration","license",
                "locals","output","provider","readme","terraform","test","tftest","tfvars",
                "unit","variable"
              ];
            def has_source($names): any(.sources[]?; . as $source | ($names | index($source)) != null);
            def is_required:
              has_source([
                "timeline_cross_reference",
                "issue_number_search_title",
                "issue_number_search_body",
                "issue_number_search_comment",
                "commit_body_refs",
                "commit_message_reference"
              ]);
            (($issue_data[0].title // "") | tokens) as $issue_title_tokens
            | (($issue_data[0].body // "") | tokens) as $issue_body_tokens
            | def compact_candidate:
                . as $candidate
                | (($candidate.title // "") | tokens) as $pr_title_tokens
                | (($candidate.body_excerpt // "") | tokens) as $pr_body_tokens
                | ([($candidate.file_names[]? // "") | tokens[]] | unique) as $pr_file_tokens
                | overlap($issue_title_tokens; $pr_title_tokens) as $title_title
                | overlap($issue_title_tokens; $pr_body_tokens) as $title_body
                | overlap($issue_body_tokens; $pr_title_tokens) as $body_title
                | overlap($issue_body_tokens; $pr_body_tokens) as $body_body
                | overlap(($issue_title_tokens + $issue_body_tokens | unique); $pr_file_tokens) as $file_matches
                | overlap($issue_title_tokens; $pr_file_tokens) as $title_file
                | (
                    $title_file
                    | map(. as $token | select((ubiquitous_file_tokens | index($token)) == null))
                  ) as $title_file_distinct
                | (
                    (($title_title | length) * 5)
                    + (($title_body | length) * 3)
                    + (($body_title | length) * 2)
                    + ([($body_body | length), 4] | min)
                    + (($file_matches | length) * 2)
                    + (($title_file_distinct | length) * 3)
                  ) as $score
                | {
                    number: $candidate.number,
                    title: $candidate.title,
                    sources: $candidate.sources,
                    url: $candidate.url,
                    state: $candidate.state,
                    draft: $candidate.draft,
                    merged: $candidate.merged,
                    body_excerpt: (($candidate.body_excerpt // "")[0:280]),
                    file_names: (($candidate.file_names // [])[0:12]),
                    file_names_truncated: (
                      ($candidate.files_truncated == true)
                      or (($candidate.file_names // []) | length > 12)
                    ),
                    open_inventory: (($candidate.sources | index("open_pr_inventory")) != null),
                    merged_inventory: (($candidate.sources | index("merged_pr_inventory")) != null),
                    lexical_relevance: {
                      version: 1,
                      score: $score,
                      plausible: (
                        ($score >= 15)
                        or (($title_title | length) >= 3)
                        or (($title_file_distinct | length) >= 2)
                      ),
                      signals: {
                        issue_title_to_pr_title: $title_title[0:10],
                        issue_title_to_pr_body: $title_body[0:10],
                        issue_body_to_pr_title: $body_title[0:10],
                        issue_body_to_pr_body: $body_body[0:10],
                        issue_identifiers_to_file_names: $file_matches[0:10],
                        issue_title_to_file_names: $title_file_distinct[0:10]
                      }
                    }
                  };
            {
              version: $version,
              issue_number: ($issue | tonumber),
              repository: $repo,
              loaded: true,
              complete: $complete,
              success: $complete,
              errors: ($errorlog | split("\n") | map(select(length > 0) | .[0:240]) | .[0:20]),
              candidate_count: ($candidates[0] | length),
              open_inventory_count: ([$candidates[0][] | select(.sources | index("open_pr_inventory"))] | length),
              merged_inventory_count: ([$candidates[0][] | select(.sources | index("merged_pr_inventory"))] | length),
              required_inspection_count: ([$candidates[0][] | select(is_required)] | length),
              required_inspection_numbers: ([$candidates[0][] | select(is_required) | .number] | unique | sort),
              required_inspection: [
                $candidates[0][] | select(is_required) | compact_candidate
              ],
              open_inventory_screening: [
                $candidates[0][] | select(is_required | not) | compact_candidate
              ]
            }
          ' > "${INDEX_FILE}" 2>>"${ERRORS_FILE}" || {
            record_error "screening index: jq generation failed"
            write_failure_contracts "screening index generation failed"
            rm -rf "${WORK_DIR}"
            exit 0
          }
        if ! jq -e --argjson expected "${CANDIDATE_COUNT}" '
          (.version == 1)
          and (.candidate_count == $expected)
          and (.required_inspection_count == (.required_inspection | length))
          and (.required_inspection_numbers == ([.required_inspection[].number] | unique | sort))
          and (([.required_inspection[].number] + [.open_inventory_screening[].number]) | length == $expected)
          and (([.required_inspection[].number] + [.open_inventory_screening[].number]) | unique | length == $expected)
          and (([.required_inspection[], .open_inventory_screening[]] | map(select(.open_inventory)) | length) == .open_inventory_count)
          and (([.required_inspection[], .open_inventory_screening[]] | map(select(.merged_inventory)) | length) == .merged_inventory_count)
          and (all(.required_inspection[]; (.sources | any(. != "open_pr_inventory" and . != "merged_pr_inventory"))))
          and (all(.open_inventory_screening[]; (.sources | length > 0) and (.sources | all(. == "open_pr_inventory" or . == "merged_pr_inventory"))))
          and (all(.required_inspection[], .open_inventory_screening[];
            (.body_excerpt | length) <= 280 and (.file_names | length) <= 12
          ))
        ' "${INDEX_FILE}" >/dev/null 2>>"${ERRORS_FILE}"; then
          record_error "screening index: count, uniqueness, or partition invariant failed"
          write_failure_contracts "screening index invariant failed"
          rm -rf "${WORK_DIR}"
          exit 0
        fi
        jq -n \
          --arg issue "${NUM}" \
          --arg repo "${REPO}" \
          --arg index_path "${INDEX_FILE}" \
          --argjson index_version "${INDEX_VERSION}" \
          --argjson complete "${COMPLETE}" \
          --slurpfile candidates "${WORK_DIR}/deduped.json" \
          --rawfile errorlog "${ERRORS_FILE}" \
          '
            def numbers_with($sources):
              [
                $candidates[0][]
                | select(any(.sources[]?; . as $source | ($sources | index($source)) != null))
                | .number
              ] | unique | sort;
            (numbers_with([
              "issue_number_search_title",
              "issue_number_search_body",
              "issue_number_search_comment"
            ])) as $exact
            | (numbers_with(["timeline_cross_reference"])) as $timeline
            | (numbers_with(["commit_body_refs","commit_message_reference"])) as $commit
            | (($exact + $timeline + $commit) | unique | sort) as $required
            | (numbers_with(["open_pr_inventory"])) as $inventory
            | (numbers_with(["merged_pr_inventory"])) as $merged_inventory
            | {
                issue_number: ($issue | tonumber),
                repository: $repo,
                loaded: true,
                complete: $complete,
                success: $complete,
                errors: ($errorlog | split("\n") | map(select(length > 0) | .[0:240]) | .[0:20]),
                candidate_count: ($candidates[0] | length),
                open_inventory_count: ($inventory | length),
                merged_inventory_count: ($merged_inventory | length),
                required_inspection_count: ($required | length),
                required_inspection_numbers: $required,
                exact_required_inspection_count: ($exact | length),
                exact_required_inspection_numbers: $exact,
                timeline_required_inspection_count: ($timeline | length),
                timeline_required_inspection_numbers: $timeline,
                commit_required_inspection_count: ($commit | length),
                commit_required_inspection_numbers: $commit,
                screening_index_path: $index_path,
                index_version: $index_version
              }
          ' > "${STATUS_FILE}"
        echo "PR candidate prefetch: candidates=${CANDIDATE_COUNT}, status=${STATUS_FILE}, index=${INDEX_FILE}, complete=${COMPLETE}"
        rm -rf "${WORK_DIR}"
    - name: Prefetch duplicate issue candidates for target issue
      env:
        GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}
        GH_AW_GITHUB_REPOSITORY: ${{ github.repository }}
        ISSUE_NUMBER: ${{ github.event.inputs.issue_number || github.event.issue.number }}
      run: |
        set -o pipefail
        mkdir -p /tmp/gh-aw/agent
        INDEX_FILE=/tmp/gh-aw/agent/issue-candidate-index.json
        INDEX_VERSION=1
        REPO="${GH_AW_GITHUB_REPOSITORY}"
        NUM="${ISSUE_NUMBER}"
        write_failure_index() {
          jq -n --arg issue "${NUM}" --arg repo "${REPO}" --arg error "$1" --argjson version "${INDEX_VERSION}" \
            '{
              version:$version,
              issue_number:($issue | tonumber? // $issue),
              repository:$repo,
              loaded:false,
              complete:false,
              success:false,
              errors:[$error],
              query_count:0,
              queries:[],
              candidate_count:0,
              open_candidate_count:0,
              must_compare:[],
              candidates:[]
            }' > "${INDEX_FILE}"
        }
        if ! printf '%s' "${REPO}" | grep -Eq '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$' \
          || ! printf '%s' "${NUM}" | grep -Eq '^[1-9][0-9]*$'; then
          write_failure_index "invalid repository or issue number"
          exit 0
        fi
        WORK_DIR=$(mktemp -d)
        ERRORS_FILE="${WORK_DIR}/errors.txt"
        RESULTS_JSONL="${WORK_DIR}/results.jsonl"
        QUERIES_JSONL="${WORK_DIR}/queries.jsonl"
        QUERY_LIST="${WORK_DIR}/queries.txt"
        : > "${ERRORS_FILE}"
        : > "${RESULTS_JSONL}"
        : > "${QUERIES_JSONL}"
        : > "${QUERY_LIST}"
        COMPLETE=true
        # Conservative fallback written up front, matching the PR prefetch contract.
        write_failure_index "duplicate prefetch step did not finish"
        record_error() {
          echo "$1" >> "${ERRORS_FILE}"
          COMPLETE=false
        }
        ISSUE_RAW="${WORK_DIR}/issue.json"
        if ! gh api "repos/${REPO}/issues/${NUM}" > "${ISSUE_RAW}" 2>>"${ERRORS_FILE}"; then
          echo '{"title":"","body":""}' > "${ISSUE_RAW}"
          record_error "issue metadata: gh api fetch failed for issue #${NUM}"
        fi
        # Derive search terms from the issue title with the same tokenizer the PR
        # screening index uses: GitHub ANDs every term, so emit short broad pairs
        # rather than one long precise query. The remedy-worded variants exist
        # because the same gap is filed twice, once as a symptom and once as a
        # feature request, and those two share almost no vocabulary.
        jq -r '
          def tokens:
            ascii_downcase
            | gsub("[^a-z0-9_]+"; " ")
            | split(" ")
            | map(. as $raw | [$raw] + (if ($raw | test("_")) then ($raw | split("_")) else [] end))
            | flatten
            | map(select(length >= 4))
            | map(
                if test("^[a-z][a-z0-9_]*s$") and length > 4 and (endswith("ss") | not)
                then .[0:-1]
                else .
                end
              )
            | . as $tokens
            | [
                "about","above","across","after","again","against","already","also","although","always",
                "among","another","appear","applied","apply","available","because","before","being","below",
                "between","body","branch","change","changes","check","checked","clear","code","configuration",
                "continue","correlation","could","current","default","description","details","during","each",
                "error","example","existing","fails","from","github","have","having","include","issue","later",
                "main","make","module","more","need","needed","other","passes","please","provider","request",
                "resource","should","state","still","than","that","their","then","there","these","they","this",
                "through","type","update","using","value","version","when","where","which","while","with","would"
              ] as $stop
            | $tokens
            | map(. as $token | select(($stop | index($token)) == null))
            | unique;
          ((.title // "") | tokens | sort_by(- length) | .[0:4]) as $top
          | (
              if ($top | length) >= 2
              then [range(0; $top | length) as $i | range($i + 1; $top | length) as $j | ($top[$i] + " " + $top[$j])]
              else $top
              end
            ) as $pairs
          | (
              $pairs
              + (
                  if ($top | length) > 0
                  then [($top[0] + " allow"), ($top[0] + " support"), ($top[0] + " custom")]
                  else []
                  end
                )
            )
          | unique
          | .[]
        ' "${ISSUE_RAW}" 2>>"${ERRORS_FILE}" | tr -d '\r' > "${QUERY_LIST}" || record_error "query derivation: jq processing failed"
        QUERY_COUNT=0
        while IFS= read -r QUERY_TERMS; do
          if [ -z "${QUERY_TERMS}" ]; then
            continue
          fi
          QUERY_COUNT=$((QUERY_COUNT + 1))
          RESPONSE="${WORK_DIR}/search-${QUERY_COUNT}.json"
          if gh api -X GET search/issues \
            -f q="repo:${REPO} is:issue ${QUERY_TERMS}" \
            -f per_page=30 > "${RESPONSE}" 2>>"${ERRORS_FILE}"; then
            jq -c --arg query "${QUERY_TERMS}" --argjson target "${NUM}" '
              {
                query: $query,
                total_count: (.total_count // 0),
                numbers: [.items[]? | select(.pull_request == null) | select(.number != $target) | .number] | unique | sort
              }
            ' "${RESPONSE}" >> "${QUERIES_JSONL}" 2>>"${ERRORS_FILE}" \
              || record_error "search: jq summary failed for query [${QUERY_TERMS}]"
            jq -c --arg query "${QUERY_TERMS}" --argjson target "${NUM}" '
              .items[]?
              | select(.pull_request == null)
              | select(.number != $target)
              | {
                  number: .number,
                  title: (.title // ""),
                  url: .html_url,
                  state: (.state // "unknown"),
                  created_at: (.created_at // ""),
                  body_excerpt: ((.body // "")[0:280]),
                  query: $query
                }
            ' "${RESPONSE}" >> "${RESULTS_JSONL}" 2>>"${ERRORS_FILE}" \
              || record_error "search: jq extraction failed for query [${QUERY_TERMS}]"
          else
            record_error "search: gh api failed for query [${QUERY_TERMS}]"
          fi
          sleep 2
        done < "${QUERY_LIST}"
        jq -s -c '.' "${RESULTS_JSONL}" > "${WORK_DIR}/results.json" 2>>"${ERRORS_FILE}" \
          || { echo '[]' > "${WORK_DIR}/results.json"; record_error "aggregation: results slurp failed"; }
        jq -s -c '.' "${QUERIES_JSONL}" > "${WORK_DIR}/queries.json" 2>>"${ERRORS_FILE}" \
          || { echo '[]' > "${WORK_DIR}/queries.json"; record_error "aggregation: queries slurp failed"; }
        jq -n \
          --arg issue "${NUM}" \
          --arg repo "${REPO}" \
          --argjson complete "${COMPLETE}" \
          --argjson version "${INDEX_VERSION}" \
          --argjson query_count "${QUERY_COUNT}" \
          --slurpfile issue_data "${ISSUE_RAW}" \
          --slurpfile results "${WORK_DIR}/results.json" \
          --slurpfile queries "${WORK_DIR}/queries.json" \
          --rawfile errorlog "${ERRORS_FILE}" \
          '
            def tokens:
              ascii_downcase
              | gsub("[^a-z0-9_]+"; " ")
              | split(" ")
              | map(. as $raw | [$raw] + (if ($raw | test("_")) then ($raw | split("_")) else [] end))
              | flatten
              | map(select(length >= 4))
              | map(
                  if test("^[a-z][a-z0-9_]*s$") and length > 4 and (endswith("ss") | not)
                  then .[0:-1]
                  else .
                  end
                )
              | . as $tokens
              | [
                  "about","above","across","after","again","against","already","also","although","always",
                  "among","another","appear","applied","apply","available","because","before","being","below",
                  "between","body","branch","change","changes","check","checked","clear","code","configuration",
                  "continue","correlation","could","current","default","description","details","during","each",
                  "error","example","existing","fails","from","github","have","having","include","issue","later",
                  "main","make","module","more","need","needed","other","passes","please","provider","request",
                  "resource","should","state","still","than","that","their","then","there","these","they","this",
                  "through","type","update","using","value","version","when","where","which","while","with","would"
                ] as $stop
              | $tokens
              | map(. as $token | select(($stop | index($token)) == null))
              | unique;
            def overlap($left; $right):
              [$left[] as $token | select(($right | index($token)) != null) | $token] | unique | sort;
            (($issue_data[0].title // "") | tokens) as $issue_title_tokens
            | (($issue_data[0].body // "") | tokens) as $issue_body_tokens
            | (
                $results[0]
                | group_by(.number)
                | map(
                    .[0] as $first
                    | ($first.title | tokens) as $cand_title_tokens
                    | ($first.body_excerpt | tokens) as $cand_body_tokens
                    | overlap($issue_title_tokens; $cand_title_tokens) as $title_title
                    | overlap($issue_title_tokens; $cand_body_tokens) as $title_body
                    | overlap($issue_body_tokens; $cand_title_tokens) as $body_title
                    | (
                        (($title_title | length) * 5)
                        + (($title_body | length) * 3)
                        + (($body_title | length) * 2)
                      ) as $score
                    | {
                        number: $first.number,
                        title: $first.title,
                        url: $first.url,
                        state: $first.state,
                        created_at: $first.created_at,
                        body_excerpt: $first.body_excerpt,
                        matched_queries: ([.[].query] | unique | sort),
                        lexical_relevance: {
                          version: 1,
                          score: $score,
                          signals: {
                            issue_title_to_candidate_title: $title_title[0:10],
                            issue_title_to_candidate_body: $title_body[0:10],
                            issue_body_to_candidate_title: $body_title[0:10]
                          }
                        }
                      }
                  )
                | sort_by(.number)
              ) as $candidates
            | ([$candidates[] | select(.state == "open") | .number] | sort) as $open_numbers
            | ([$candidates[]
                | select(.lexical_relevance.score >= 12)]
               | sort_by(-.lexical_relevance.score, .number)
               | .[0:6]
               | map(.number)) as $must_compare
            | {
                version: $version,
                issue_number: ($issue | tonumber),
                repository: $repo,
                loaded: true,
                complete: $complete,
                success: $complete,
                errors: ($errorlog | split("\n") | map(select(length > 0) | .[0:240]) | .[0:20]),
                query_count: $query_count,
                queries: $queries[0],
                candidate_count: ($candidates | length),
                open_candidate_count: ($open_numbers | length),
                must_compare: $must_compare,
                candidates: $candidates
              }
          ' > "${INDEX_FILE}"
        echo "Duplicate candidate prefetch: queries=${QUERY_COUNT}, index=${INDEX_FILE}, complete=${COMPLETE}"
        rm -rf "${WORK_DIR}"
    - name: Render triage evidence blocks
      run: |
        set -o pipefail
        AGENT_DIR=/tmp/gh-aw/agent
        mkdir -p "${AGENT_DIR}"
        DUP_INDEX="${AGENT_DIR}/issue-candidate-index.json"
        PR_STATUS="${AGENT_DIR}/pr-candidate-status.json"
        PR_INDEX="${AGENT_DIR}/pr-candidate-screening-index.json"
        AUDIT_FILE="${AGENT_DIR}/triage-audit-block.md"
        STATUS_LINE="${AGENT_DIR}/triage-screening-status.md"
        VALIDATION_FILE="${AGENT_DIR}/pr-evidence-validation.json"
        printf '%s\n' '{"valid":false}' > "${VALIDATION_FILE}"
        # The validation programs below are the deterministic contracts the prompt used
        # to ask the agent to run by hand. Evaluating them here keeps ~5KB of dense
        # filter syntax out of the model-facing prompt, and means a run cannot report
        # that the invariants passed unless they were actually evaluated.
        AUDIT_FALLBACK='- Prefetched duplicate searches: the deterministic duplicate index did not load, so no prefetched search record is available for this run. Do not close this issue as a duplicate in this run.'
        STATUS_FALLBACK='- **PR-evidence and screening status:** the deterministic PR evidence contracts did not pass, so screening counts and candidate numbers are unavailable for this run. Confirmed-fix closure and PR linking were skipped; duplicate-closure decisions are unaffected.'
        fallback() {
          printf '%s\n' "$2" > "$1"
          echo "render: $3; wrote fallback line to $1"
        }
        render_audit() {
          if [ ! -s "${DUP_INDEX}" ]; then
            fallback "${AUDIT_FILE}" "${AUDIT_FALLBACK}" "duplicate index missing or empty"
            return
          fi
          if ! jq -e '. as $index | type == "object" and .loaded == true and .complete == true and .success == true and (.errors == []) and (.version == 1) and (.query_count | type == "number") and (.queries | type == "array") and (.candidate_count | type == "number") and (.candidates | type == "array") and (.open_candidate_count | type == "number") and (.must_compare | type == "array") and ((.must_compare - [.candidates[].number]) == []) and (.query_count == (.queries | length)) and (.candidate_count == (.candidates | length)) and (.open_candidate_count == ([.candidates[] | select(.state == "open")] | length)) and ([.candidates[].number] | unique | length) == .candidate_count and (all(.queries[]; (.query | type == "string") and (.numbers | type == "array"))) and (all(.candidates[]; (.number | type == "number") and (.title | type == "string") and (.state | type == "string") and (.created_at | type == "string") and (.url | type == "string") and (.body_excerpt | type == "string") and (.body_excerpt | length) <= 280 and (.matched_queries | type == "array") and (.matched_queries | length > 0) and (.lexical_relevance.score | type == "number") and (.lexical_relevance.signals | type == "object")))' "${DUP_INDEX}" > /dev/null 2>&1; then
            fallback "${AUDIT_FILE}" "${AUDIT_FALLBACK}" "duplicate index failed its contract"
            return
          fi
          if ! jq -r '
              def numlist($nums):
                if (($nums // []) | length) == 0 then "none"
                else (($nums // []) | map("#" + (. | tostring)) | join(", "))
                end;
              ["- Prefetched duplicate searches (from `issue-candidate-index.json`):"]
              + (
                  .queries
                  | map(
                      "  - `" + (.query // "") + "` → "
                      + (
                          if (((.numbers // []) | length) == 0) then "no results"
                          else ((.numbers // []) | map("`#" + (. | tostring) + "`") | join(", "))
                          end
                        )
                    )
                )
              + ["- Candidates requiring explicit comparison: " + numlist(.must_compare)]
              | .[]
            ' "${DUP_INDEX}" > "${AUDIT_FILE}"; then
            fallback "${AUDIT_FILE}" "${AUDIT_FALLBACK}" "audit render failed"
            return
          fi
          if [ ! -s "${AUDIT_FILE}" ]; then
            fallback "${AUDIT_FILE}" "${AUDIT_FALLBACK}" "audit render produced no output"
            return
          fi
          echo "Audit block rendered: $(wc -l < "${AUDIT_FILE}") line(s) -> ${AUDIT_FILE}"
        }
        render_status() {
          if [ ! -s "${PR_STATUS}" ] || [ ! -s "${PR_INDEX}" ]; then
            fallback "${STATUS_LINE}" "${STATUS_FALLBACK}" "PR status or screening index missing or empty"
            return
          fi
          if ! jq -e '. as $status | type == "object" and .loaded == true and .complete == true and .success == true and (.errors == []) and (.candidate_count | type == "number") and (.open_inventory_count | type == "number") and (.merged_inventory_count | type == "number") and (.required_inspection_count | type == "number") and (.required_inspection_numbers | type == "array") and (.exact_required_inspection_count | type == "number") and (.exact_required_inspection_numbers | type == "array") and (.timeline_required_inspection_count | type == "number") and (.timeline_required_inspection_numbers | type == "array") and (.commit_required_inspection_count | type == "number") and (.commit_required_inspection_numbers | type == "array") and (.required_inspection_count == (.required_inspection_numbers | length)) and (.exact_required_inspection_count == (.exact_required_inspection_numbers | length)) and (.timeline_required_inspection_count == (.timeline_required_inspection_numbers | length)) and (.commit_required_inspection_count == (.commit_required_inspection_numbers | length)) and (.required_inspection_numbers == ((.exact_required_inspection_numbers + .timeline_required_inspection_numbers + .commit_required_inspection_numbers) | unique | sort)) and (.required_inspection_count <= .candidate_count) and (.open_inventory_count <= .candidate_count) and (.merged_inventory_count <= .candidate_count) and (.screening_index_path | type == "string") and (.index_version == 1)' "${PR_STATUS}" > /dev/null 2>&1; then
            fallback "${STATUS_LINE}" "${STATUS_FALLBACK}" "PR status failed its contract"
            return
          fi
          if ! jq -e '. as $index | type == "object" and .loaded == true and .complete == true and .success == true and (.errors == []) and (.version == 1) and (.candidate_count | type == "number") and (.open_inventory_count | type == "number") and (.required_inspection_count | type == "number") and (.required_inspection_numbers | type == "array") and (.required_inspection | type == "array") and (.open_inventory_screening | type == "array") and (.required_inspection_count == (.required_inspection | length)) and (.required_inspection_numbers == ([.required_inspection[].number] | unique | sort)) and (([.required_inspection[].number] + [.open_inventory_screening[].number]) | length == $index.candidate_count) and (([.required_inspection[].number] + [.open_inventory_screening[].number]) | unique | length == $index.candidate_count) and (([.required_inspection[], .open_inventory_screening[]] | map(select(.open_inventory)) | length) == $index.open_inventory_count) and (([.required_inspection[], .open_inventory_screening[]] | map(select(.merged_inventory)) | length) == $index.merged_inventory_count) and (all(.required_inspection[]; (.sources | any(. != "open_pr_inventory" and . != "merged_pr_inventory")))) and (all(.open_inventory_screening[]; (.sources | length > 0) and (.sources | all(. == "open_pr_inventory" or . == "merged_pr_inventory")) and (.open_inventory or .merged_inventory))) and (all(.required_inspection[], .open_inventory_screening[]; (.number | type == "number") and (.title | type == "string") and (.sources | type == "array") and (.url | type == "string") and (.state | type == "string") and (.draft | type == "boolean") and (.merged | type == "boolean") and (.body_excerpt | type == "string") and (.body_excerpt | length) <= 280 and (.file_names | type == "array") and (.file_names | length) <= 12 and (.file_names_truncated | type == "boolean") and (.open_inventory | type == "boolean") and (.merged_inventory | type == "boolean") and (.lexical_relevance.score | type == "number") and (.lexical_relevance.plausible | type == "boolean") and (.lexical_relevance.signals | type == "object")))' "${PR_INDEX}" > /dev/null 2>&1; then
            fallback "${STATUS_LINE}" "${STATUS_FALLBACK}" "PR screening index failed its contract"
            return
          fi
          if ! jq -e -n --slurpfile s "${PR_STATUS}" --slurpfile i "${PR_INDEX}" '
              ($s[0].candidate_count == $i[0].candidate_count)
              and ($s[0].open_inventory_count == $i[0].open_inventory_count)
              and ($s[0].merged_inventory_count == $i[0].merged_inventory_count)
              and ($s[0].required_inspection_count == $i[0].required_inspection_count)
              and ($s[0].required_inspection_numbers == $i[0].required_inspection_numbers)
            ' > /dev/null 2>&1; then
            fallback "${STATUS_LINE}" "${STATUS_FALLBACK}" "PR status and screening index disagree on counts"
            return
          fi
          if ! jq -r '
              def numlist($nums):
                if (($nums // []) | length) == 0 then "none"
                else (($nums // []) | sort | map("`#" + (. | tostring) + "`") | join(", "))
                end;
              ([.open_inventory_screening[]
                | select(.lexical_relevance.plausible == true)
                | .number] | unique | sort) as $plausible
              | "- **PR-evidence and screening status:** `candidate_count`: \(.candidate_count), "
                + "`open_inventory_count`: \(.open_inventory_count), "
                + "`merged_inventory_count`: \(.merged_inventory_count), "
                + "`required_inspection_count`: \(.required_inspection_count). "
                + "Required inspection: \(numlist(.required_inspection_numbers)). "
                + "Lexically plausible (full inspection mandatory): \(numlist($plausible)). "
                + "Direct status/index parses succeeded and all count/inspection invariants passed."
            ' "${PR_INDEX}" > "${STATUS_LINE}"; then
            fallback "${STATUS_LINE}" "${STATUS_FALLBACK}" "status render failed"
            return
          fi
          if [ ! -s "${STATUS_LINE}" ]; then
            fallback "${STATUS_LINE}" "${STATUS_FALLBACK}" "status render produced no output"
            return
          fi
          echo "Screening status rendered -> ${STATUS_LINE}"
          cat "${STATUS_LINE}"
          printf '%s\n' '{"valid":true}' > "${VALIDATION_FILE}"
        }
        render_audit
        render_status
    - name: Prepare release proof verifier
      run: |
        mkdir -p /tmp/gh-aw/agent
        cat <<'TRIAGE_RELEASE_VERIFIER' > /tmp/gh-aw/agent/triage-release-proof.sh
        set -euo pipefail
        MODE="${1:?mode required}"
        AGENT_DIR="${2:?evidence directory required}"
        OUT="${3:?output path required}"
        SELECTED_PR="${4:-}"
        REPO="${GH_AW_GITHUB_REPOSITORY}"
        WORK_DIR=$(mktemp -d)
        trap 'rm -rf "${WORK_DIR}"' EXIT
        NUMBERS='[]'
        HAS_RELEASE=null
        LATEST_TAG=''
        LATEST_PUBLISHED_AT=''
        # Bound API work without treating an exhausted budget as negative evidence.
        REQUEST_LIMIT=200
        DEADLINE=$((SECONDS + 180))
        printf '0\n' > "${WORK_DIR}/request-count"
        api() {
          local count
          count=$(cat "${WORK_DIR}/request-count")
          if [ "${count}" -ge "${REQUEST_LIMIT}" ] || [ "${SECONDS}" -ge "${DEADLINE}" ]; then
            touch "${WORK_DIR}/budget-exhausted"
            return 1
          fi
          printf '%s\n' "$((count + 1))" > "${WORK_DIR}/request-count"
          timeout 20s gh api "$@"
        }
        write_unknown() {
          local reason="$1"
          if [ -f "${WORK_DIR}/budget-exhausted" ]; then reason=request_budget_exhausted; fi
          jq -n --arg reason "${reason}" --argjson loaded "${2:-false}" \
            --argjson numbers "${NUMBERS}" --argjson has_release "${HAS_RELEASE}" \
            --arg tag "${LATEST_TAG}" --arg published "${LATEST_PUBLISHED_AT}" '
            {
              version:1, loaded:$loaded, has_release:$has_release,
              latest_tag:(($tag | select(length > 0)) // null),
              latest_published_at:(($published | select(length > 0)) // null),
              reason:$reason,
              prs:[$numbers[] | {number:., status:"unknown", reason:$reason, release_tag:null}]
            }' > "${OUT}"
          echo "Release evidence: ${reason}"
        }
        # An interrupted lookup must leave unknown, never an empty negative list.
        write_unknown "lookup_incomplete"
        case "${MODE}" in
          prefetched)
            if ! NUMBERS=$(jq -ce '
              [.required_inspection[], .open_inventory_screening[]] | map(.number) | unique | sort
              | select(all(.[]; type == "number" and . > 0 and floor == .))
            ' "${AGENT_DIR}/pr-candidate-screening-index.json"); then
              NUMBERS='[]'
              write_unknown "candidate_index_unavailable"
              exit 0
            fi
            if ! jq -e '.valid == true' "${AGENT_DIR}/pr-evidence-validation.json" > /dev/null; then
              write_unknown "incomplete_pr_evidence"
              exit 0
            fi
            ;;
          selected)
            # Selection is separate from discovery. Never fabricate an index or
            # validation marker for a PR found outside the initial snapshot.
            if ! printf '%s' "${SELECTED_PR}" | grep -Eq '^[1-9][0-9]{0,15}$' ||
               ! NUMBERS=$(jq -cen --arg n "${SELECTED_PR}" '($n | tonumber) | select(. <= 9007199254740991 and floor == .) | [.]'); then
              NUMBERS='[]'
              write_unknown "invalid_selected_pr"
              exit 0
            fi
            ;;
          *)
            write_unknown "invalid_verification_mode"
            exit 0
            ;;
        esac
        if ! printf '%s' "${REPO}" | grep -Eq '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$'; then
          write_unknown "invalid_repository"
          exit 0
        fi
        write_unknown "lookup_incomplete"
        if [ -z "${DEFAULT_BRANCH}" ]; then
          write_unknown "default_branch_unavailable"
          exit 0
        fi
        # Enumerate every stable release, newest publication first. An older release can contain a fix missing from a newer maintenance release.
        if ! api --paginate "repos/${REPO}/releases?per_page=100" > "${WORK_DIR}/release-pages.json" ||
           ! jq -se '
             select(length > 0 and all(.[]; type == "array"))
             | add
             | select(all(.[];
                 (.draft | type == "boolean") and (.prerelease | type == "boolean")))
             | map(select(.draft == false and .prerelease == false))
             | select(all(.[];
                 (.id | type == "number" and . > 0 and floor == .)
                 and (.tag_name | type == "string" and test("^[^[:space:]]+$"))
                 and (.published_at | type == "string" and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$"))))
             | . as $releases
             | select(
                 ([$releases[].id] | unique | length) == ($releases | length)
                 and ([$releases[].tag_name] | unique | length) == ($releases | length))
             | sort_by(.published_at, .id) | reverse
           ' "${WORK_DIR}/release-pages.json" > "${WORK_DIR}/releases.json"; then
          write_unknown "release_list_unavailable"
          exit 0
        fi
        if [ "$(jq length "${WORK_DIR}/releases.json")" -eq 0 ]; then
          HAS_RELEASE=false
          write_unknown "no_published_release" true
          exit 0
        fi
        HAS_RELEASE=true
        LATEST_TAG=$(jq -r '.[0].tag_name' "${WORK_DIR}/releases.json")
        LATEST_PUBLISHED_AT=$(jq -r '.[0].published_at' "${WORK_DIR}/releases.json")
        write_unknown "lookup_incomplete"
        resolve_commit() {
          local encoded
          encoded=$(jq -rn --arg ref "$1" '$ref | @uri')
          api "repos/${REPO}/commits/${encoded}" > "$2" &&
            jq -er '.sha | select(type == "string" and test("^[0-9a-f]{40}$"))' "$2"
        }
        if ! DEFAULT_SHA=$(resolve_commit "refs/heads/${DEFAULT_BRANCH}" "${WORK_DIR}/default.json"); then
          write_unknown "default_branch_unavailable"
          exit 0
        fi
        compare_commits() {
          # Only the ancestry summary is consumed. GitHub can truncate .commits at 250 entries; neither that array nor commit-message #references is proof.
          api "repos/${REPO}/compare/$1...$2?per_page=1" > "${WORK_DIR}/comparison.json" &&
            jq -er --arg base "$1" --arg head "$2" '
              select(.base_commit.sha == $base)
              | select(.merge_base_commit.sha | type == "string" and test("^[0-9a-f]{40}$"))
              | select(.ahead_by | type == "number" and . >= 0 and floor == .)
              | select(.behind_by | type == "number" and . >= 0 and floor == .)
              | select(
                  (.status == "identical" and $base == $head and .merge_base_commit.sha == $base and .ahead_by == 0 and .behind_by == 0)
                  or (.status == "ahead" and $base != $head and .merge_base_commit.sha == $base and .ahead_by > 0 and .behind_by == 0)
                  or (.status == "behind" and $base != $head and .merge_base_commit.sha == $head and .ahead_by == 0 and .behind_by > 0)
                  or (.status == "diverged" and $base != $head and .merge_base_commit.sha != $base and .merge_base_commit.sha != $head and .ahead_by > 0 and .behind_by > 0))
              | .status
            ' "${WORK_DIR}/comparison.json"
        }
        RESULTS="${WORK_DIR}/results.jsonl"
        : > "${RESULTS}"
        write_pr() {
          local reason="$2"
          if [ "$1" = unknown ] && [ -f "${WORK_DIR}/budget-exhausted" ]; then reason=request_budget_exhausted; fi
          jq -cn --argjson number "${NUMBER}" --arg status "$1" --arg reason "${reason}" --arg tag "${3:-}" \
            '{number:$number, status:$status, reason:$reason, release_tag:(($tag | select(length > 0)) // null)}' >> "${RESULTS}"
        }
        jq -r '.[] | [.id, .tag_name] | @tsv' "${WORK_DIR}/releases.json" > "${WORK_DIR}/release-refs.tsv"
        for NUMBER in $(jq -r '.[]' <<< "${NUMBERS}"); do
          if [ -f "${WORK_DIR}/budget-exhausted" ]; then
            write_pr unknown request_budget_exhausted
            continue
          fi
          PR="${WORK_DIR}/pr.json"
          if ! api "repos/${REPO}/pulls/${NUMBER}" > "${PR}" ||
             ! jq -e --argjson number "${NUMBER}" '
               .number == $number and (.merged | type == "boolean") and (.draft | type == "boolean")
             ' "${PR}" > /dev/null; then
            write_pr unknown pr_metadata_unavailable
            continue
          fi
          # Before merging, merge_commit_sha is a test merge, not a shipped commit.
          if ! jq -e '.merged == true and .draft == false' "${PR}" > /dev/null; then
            write_pr unknown pr_not_merged
            continue
          fi
          if ! jq -e --arg repo "${REPO}" --arg branch "${DEFAULT_BRANCH}" \
            '.base.repo.full_name == $repo and .base.ref == $branch' "${PR}" > /dev/null; then
            write_pr unknown pr_not_targeting_default_branch
            continue
          fi
          if ! MERGE_SHA=$(jq -er '.merge_commit_sha | select(type == "string" and test("^[0-9a-f]{40}$"))' "${PR}"); then
            write_pr unknown merge_commit_unavailable
            continue
          fi
          if ! DEFAULT_RELATION=$(compare_commits "${MERGE_SHA}" "${DEFAULT_SHA}") ||
             { [ "${DEFAULT_RELATION}" != ahead ] && [ "${DEFAULT_RELATION}" != identical ]; }; then
            write_pr unknown default_branch_membership_unverified
            continue
          fi
          STATUS=awaiting_release
          REASON=all_releases_precede_merge_commit
          RELEASE_TAG=''
          while IFS=$'\t' read -r RELEASE_ID TAG; do
            # Cache each tag's resolved commit once per run. These internal SHAs are removed on exit and never become agent-visible reference data.
            PIN="${WORK_DIR}/release-${RELEASE_ID}.sha"
            if [ ! -f "${PIN}" ]; then
              if ! resolve_commit "refs/tags/${TAG}" "${WORK_DIR}/tag.json" > "${PIN}"; then
                : > "${PIN}"
              fi
            fi
            RELEASE_SHA=$(cat "${PIN}")
            if [ -z "${RELEASE_SHA}" ]; then
              STATUS=unknown
              REASON=release_tag_unavailable
              if [ -f "${WORK_DIR}/budget-exhausted" ]; then break; fi
              continue
            fi
            if ! RELATION=$(compare_commits "${MERGE_SHA}" "${RELEASE_SHA}"); then
              STATUS=unknown
              REASON=release_comparison_unavailable
              if [ -f "${WORK_DIR}/budget-exhausted" ]; then break; fi
              continue
            fi
            case "${RELATION}" in
              ahead|identical)
                STATUS=released
                REASON=release_contains_merge_commit
                RELEASE_TAG="${TAG}"
                break
                ;;
              diverged)
                STATUS=unknown
                REASON=release_history_diverged
                ;;
            esac
          done < "${WORK_DIR}/release-refs.tsv"
          write_pr "${STATUS}" "${REASON}" "${RELEASE_TAG}"
        done
        jq -s --arg tag "${LATEST_TAG}" --arg published "${LATEST_PUBLISHED_AT}" '
          {version:1, loaded:true, has_release:true, latest_tag:$tag,
           latest_published_at:$published, reason:null, prs:.}
        ' "${RESULTS}" > "${OUT}"
        TRIAGE_RELEASE_VERIFIER
    - name: Fetch release status
      env:
        GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}
        GH_AW_GITHUB_REPOSITORY: ${{ github.repository }}
        DEFAULT_BRANCH: ${{ github.event.repository.default_branch }}
      run: |
        bash /tmp/gh-aw/agent/triage-release-proof.sh prefetched /tmp/gh-aw/agent /tmp/gh-aw/agent/release-status.json
    - name: Seal triage evidence
      id: seal-triage-evidence
      uses: actions/github-script@3a2844b7e9c422d3c10d287c895573f7108da1b3
      env:
        TRIAGE_REPOSITORY: ${{ github.repository }}
        TRIAGE_ISSUE: ${{ github.event.inputs.issue_number || github.event.issue.number }}
        TRIAGE_DEFAULT_BRANCH: ${{ github.event.repository.default_branch }}
        TRIAGE_WORKFLOW_SHA: ${{ github.workflow_sha }}
      with:
        script: |
          const fs = require('fs');
          const path = require('path');
          const crypto = require('crypto');
          const directory = '/tmp/gh-aw/agent';
          const producerAttempt = process.env.GITHUB_RUN_ATTEMPT;
          if (!/^[1-9][0-9]*$/.test(producerAttempt || '') || !Number.isSafeInteger(Number(producerAttempt)))
            throw new Error('Invalid producer run attempt');
          const files = ['repo-labels.json', 'issue-number.txt', 'issue-type.txt', 'issue-state-history.json', 'pr-candidate-status.json', 'pr-candidate-screening-index.json', 'issue-candidate-index.json', 'triage-audit-block.md', 'triage-screening-status.md', 'pr-evidence-validation.json', 'release-status.json', 'triage-release-proof.sh'];
          const hashes = {};
          for (const name of files) {
            const file = path.join(directory, name);
            if (!fs.lstatSync(file).isFile()) throw new Error(`Not a regular evidence file: ${name}`);
            hashes[name] = crypto.createHash('sha256').update(fs.readFileSync(file)).digest('hex');
          }
          const manifest = JSON.stringify({
            version: 1, repository: process.env.TRIAGE_REPOSITORY, issue_number: process.env.TRIAGE_ISSUE,
            run_id: process.env.GITHUB_RUN_ID, run_attempt: producerAttempt,
            workflow_sha: process.env.TRIAGE_WORKFLOW_SHA, default_branch: process.env.TRIAGE_DEFAULT_BRANCH, files: hashes
          });
          fs.writeFileSync(path.join(directory, 'triage-evidence-manifest.json'), manifest);
          core.setOutput('sha256', crypto.createHash('sha256').update(manifest).digest('hex'));
          core.setOutput('producer_attempt', producerAttempt);
    - name: Upload trusted triage evidence
      id: upload-triage-evidence
      uses: actions/upload-artifact@043fb46d1a93c77aae656e7c1c64a875d1fc6a0a
      with:
        name: triage-evidence-${{ github.run_id }}-${{ github.run_attempt }}
        path: /tmp/gh-aw/agent
        if-no-files-found: error
        overwrite: false
  agent:
    needs: [triage_evidence]
  safe_outputs:
    permissions:
      contents: read
steps:
# Workaround for github/gh-aw#52327: when the installer finds a cached
# copilot-cli within its 14-day TTL it only prepends the cache dir to PATH and
# never writes /usr/local/bin/copilot, but the agent harness spawns that exact
# path and fails with ENOENT. Removing the cache forces the download branch,
# which does write /usr/local/bin/copilot. Remove once upstream is fixed.
- name: Force Copilot CLI download (workaround github/gh-aw#52327)
  run: sudo rm -rf /opt/hostedtoolcache/copilot-cli || true
- name: Download triage evidence for investigation
  uses: actions/download-artifact@3e5f45b2cfb9172054b4087a40e8e0b5a5461e7c
  with:
    artifact-ids: ${{ needs.triage_evidence.outputs.artifact_id }}
    path: /tmp/gh-aw/agent
    merge-multiple: true
tools:
  cache-memory: true
  github:
    min-integrity: none
    toolsets:
    - default
  web-fetch: {}
mcp-servers:
  microsoftdocs:
    url: "https://learn.microsoft.com/api/mcp"
    allowed: ["*"]
---

# Azure Verified Modules Terraform Module Issue Triage

You are an AI agent that performs initial triage on newly created or reopened issues in the **${{ github.repository }}** repository.

This repository contains the Terraform code for a single Azure Verified Module (AVM) module. The issue, the labels, the releases, and the code to investigate are all in this repository.

> **Target issue for this run: #${{ github.event.inputs.issue_number || github.event.issue.number }}**
> Always use this number as `item_number` in issue safe output calls (`add-comment`, `add-labels`). Use it as `issue_number` for `close-issue` and `set-issue-type`. When updating a pull request, use its number as `pull_request_number`.

## Your Task

When a new issue is created or reopened, perform the following steps **in order**:

1. **Read the issue and its history** — Understand the title, body, labels, and timeline. Determine whether this workflow previously closed the issue and a person later reopened it; if so, permanently disable automated closure for this issue.
2. **Check for duplicates** — Search for existing open **and** closed issues in this repository that are similar or identical.
3. **Set the issue type and attach labels** — Choose the best matching GitHub issue type and attach appropriate labels that already exist on the repository.
4. **Discover related PRs and check for existing fixes** — Search broadly for linked and unlinked PRs, validate candidate PRs by reading their changes, link only clear fixes, and determine whether the issue is conclusively resolved.
5. **Investigate and suggest a fix** — Where possible, look at the relevant source code in this repository and suggest what the fix may be. If the issue is a question or a feature request rather than a bug, note that clearly.
6. **Post a triage summary comment** — Summarise what you did in a single comment on the issue. **Do not emit any safe outputs until all analysis steps are complete.**

---

## Step 1: Read the Issue

Read the full issue title and body for issue **#${{ github.event.inputs.issue_number || github.event.issue.number }}** (also available in `/tmp/gh-aw/agent/issue-number.txt`). Note:

- Key terms, error messages, file paths, resource names, variable names, output names, or module references.
- Whether the issue mentions a Terraform plan/apply error, a provider version, an example, a variable, or a specific Azure resource.
- Any `.tf`, `.tfvars`, `.tftest.hcl`, `.terraform.lock.hcl`, or Terraform CLI references that indicate the deployment path.
- If the issue lacks a minimal reproduction (config snippet, provider/module versions, exact error), prefer `needs-more-info` over guessing a root cause.
- Read `/tmp/gh-aw/agent/issue-state-history.json` and earlier comments from this workflow. The history file records close/reopen event timestamps and actor identities.

### Human Reopen Override

If the state history and earlier workflow comments show that this agentic triage workflow previously closed the issue, and a person subsequently reopened it, treat that reopen as an explicit request for human review. Correlate this workflow's prior triage authorization comment and native close-body comment with the subsequent close event by the workflow actor. Older workflow comments may say "closing" rather than "authorized". Authorization alone is not evidence that a native close succeeded; require the close event. Do not attribute another automation's closure to this workflow.

- Set a **human-reopened-after-agent-closure** flag for the rest of the run.
- Never call `close-issue` for this issue again, with any `state_reason`. This veto applies to both duplicate and completed closures and to manual reruns because the reopen remains in the issue timeline.
- Continue the full analysis. You may add labels, refresh the triage comment, and append `Fixes #<issue-number>` to a confirmed-fix PR when appropriate.
- In the triage comment, state that automated closure was skipped because the issue was reopened after an earlier agent closure and should remain open for a human maintainer.

Do not activate this override merely because the issue is currently in the `reopened` event. Confirm from the ordered history that this workflow performed the earlier closure and that a later reopen event has an actor with `type: User`, not a bot or workflow. A reopen after a human closure does not by itself create this automated-closure veto.

If the history file is missing, unreadable, or has `loaded: false`, do not perform any automated closure in this run because you cannot safely rule out a prior human reopen. Continue the analysis and state in the triage comment that closure was skipped because issue state history could not be verified.

### Prior Triage Comments Are Not Evidence

Earlier triage comments on this issue — including ones you wrote in previous runs — record what was true **when they were written**, not what is true now. A fix may have merged since.

- Use them only for state history (above) and to avoid repeating identical advice verbatim.
- **Never restate a factual claim from an earlier comment about repository contents** — which files, tests, examples, variables, or fixes exist — without re-verifying it against the current default branch **in this run**. A claim that something is missing is the one most likely to have gone stale.
- **Never cite agreement between previous runs as support.** Repeated output is one observation, not several; a stale claim repeats perfectly. Phrases like "previous runs reached the same conclusion" are not evidence and must not appear in your comment.
- If you cannot re-verify an inherited claim this run, drop it rather than repeat it.

---

## Step 2: Check for Duplicates

### Deterministic Duplicate Candidate Contract (read this first)

A pre-agent step has already issued a fixed set of issue searches, validated the result against a strict schema and count contract, and written `/tmp/gh-aw/agent/issue-candidate-index.json`. Read it **before** searching yourself:

```bash
jq '{query_count,candidate_count,open_candidate_count,must_compare,queries:[.queries[] | {query,total_count,matched:(.numbers | length)}]}' /tmp/gh-aw/agent/issue-candidate-index.json
jq '.candidates[] | {number,title,state,created_at,url,body_excerpt,matched_queries,lexical_relevance}' /tmp/gh-aw/agent/issue-candidate-index.json
```

You do not have to validate the file. If its contract failed, the rendered audit block at `/tmp/gh-aw/agent/triage-audit-block.md` says so in place of the query list, and that is your signal that the deterministic duplicate search is unavailable: say so in your triage comment, run your own searches, and **do not close this issue as a duplicate in this run**.

The queries are derived from the issue title by a fixed tokenizer, not by the model: it takes the four most distinctive title terms, issues every pair of them, and adds remedy-worded variants of the strongest term (`allow`, `support`, `custom`) so a feature-request framing of the same gap is reachable. This is a **floor, not a ceiling** — it cannot know the issue's error text, and it cannot paraphrase.

**Screen every entry in `.candidates`** and open the promising ones. `lexical_relevance.score` orders your reading; it does not decide anything and does not prove a shared root cause.

**`.must_compare` is mandatory reading.** It holds the highest-scoring candidates, and every issue in it **must be opened and read this run** — not skimmed from its title or `body_excerpt`, which are truncated and routinely hide the sentence that decides the match. Account for **every** number in `.must_compare` in your Duplicate check bullet with a short verdict each: duplicate, possible duplicate, related, or not related, with a few words of reason. A number you never mention reads as a candidate you never opened.

This obligation is about **reading, not deciding**. A high score never justifies a closure on its own, and a candidate you were required to open is very often correctly dismissed — say so explicitly instead of omitting it. Conversely, a duplicate may be an issue that is *not* in `.must_compare`: the list is the mandatory floor, never the full set of things worth comparing.

### Additional Searching

The prefetched queries are mechanical. Add your own, using `search_issues` — `search_repositories` searches for repositories, not issues, and cannot answer this question. Anything you turn up this way is reported as a **finding** — the issue number and why it matches — never as a description of the query that found it; see *The search record is rendered for you* below.

Search **${{ github.repository }}** for existing issues (both open and closed) that report the **same underlying problem**, even if they are worded differently. Reworded or paraphrased reports are still duplicates — do not rely on title or keyword overlap alone.

**How to build queries.** GitHub ANDs every term, so each extra word can only shrink the result set. Keep each query to **two or three broad terms** and run **several separate queries** rather than one precise query. Prefer the words that would appear in *any* report of this problem — the affected input, resource, or behaviour — and leave out qualifiers, verbs, and framing words. For example, prefer `whitespace name` over `trim leading whitespace vnet name`.

Cover what the prefetch structurally cannot:

- A distinctive substring of any **error message**, on its own.
- The affected provider, resource, variable, output, or module name (e.g. `modtm`, `enable_telemetry`, `azapi`).
- **The vocabulary of the fix**, as its own query — never appended to a symptom query. The same gap is routinely filed twice: once as a bug describing the *symptom* ("the module overwrites my lock notes on every apply") and once as a feature request describing the *remedy* ("allow setting custom lock notes"). These share almost no wording, so only a separate remedy-worded search will find the pair. A bug-vs-feature framing difference is irrelevant to whether two issues are the same underlying problem.

Then **open the most promising candidate issues and compare them semantically** — decide whether they describe the same root cause, not just whether the text matches. Include very recently opened issues, since a duplicate may have been filed only minutes earlier.

**Choosing the canonical issue.** Collect every match you judge to be the same underlying problem, then list them as `#<number>` with state and creation date, sorted by number ascending. The canonical issue is the **lowest-numbered one that is still open**. Note that this is computed over the matches *you judged to be duplicates*, never over the raw prefetched candidate list — a search hit is not a duplicate. Only if every match is closed do you fall back to the lowest-numbered closed one. Do not link the match you happened to find first, and do not link a newer issue while an older open one tracks the same problem.

### Duplicate Handling Rules

Finding a candidate above does **not** by itself mean you close. Closing is a separate, deliberate decision with a **high bar**. Sort each candidate you found into one of these tiers:

- **Confirmed duplicate (close):** Close as a duplicate **only** when you are **highly confident** the two issues are the **same underlying problem / root cause** and the Human Reopen Override is not active — the wording or framing may differ, but the actual defect, request, or question is the same and re-reporting it adds no new information. First post your triage comment (see Step 6 — Duplicate Closure Flow) explaining the match, then use the `close-issue` safe output. This closes the issue with the `duplicate` state reason and links it to the canonical issue. This decision is governed only by these duplicate rules: it does not depend on, and is never weakened by, the Step 4 PR-evidence prefetch or the state of any related fix PR — close as a duplicate even if a topically related PR is still open, draft, or unmerged, or if that PR's own evidence load was incomplete.
- **Possible duplicate (do NOT close, but link):** You found a strong candidate that looks like the same problem, but you are **not** highly confident — e.g. it overlaps heavily yet also raises a distinct question, adds new context, or you cannot fully confirm the same root cause. **Leave the issue open.** In your triage comment, explicitly flag it as `Possible duplicate of #N` with a link so triagers can make the final call. Do **not** apply the `duplicate` label in this tier (that label is only for issues you actually close).
- **Related / similar (do NOT close):** Touches a related area but is a **different** root cause, request, or question. Mention it as a related issue in your triage comment. Leave the issue open.
- **No duplicates found:** Note this in your triage comment.

**Bias toward leaving open.** Wrongly closing a valid issue is much worse than leaving a duplicate open. Whenever you are not **highly confident** it is the same root cause, do not close — downgrade to *Possible duplicate* and link it instead. Never close based on surface or topic similarity alone.

**The search record is rendered for you; do not write it yourself.** Read `/tmp/gh-aw/agent/triage-audit-block.md` for the trusted duplicate-search audit. The output gate inserts its own verified copy into the final comment. In `add_comment.data.audit`, list only the other sources you actually opened and your candidate verdicts, identified by issue number or file path. Do not repeat the computed audit or counts.

**Never describe your own searching in the findings or audit.** The trusted audit block is the published search record. If your investigation surfaced a candidate the prefetch missed, report the issue number and why it matches, not the query that found it.

If the index failed to load and you were also unable to run any search, say exactly that in the visible comment ("No duplicate search was performed") rather than reporting that none were found; those are different statements and only one of them is true.

---

## Step 3: Set the Issue Type and Attach Labels

The repository label definitions are available at `/tmp/gh-aw/agent/repo-labels.json`. **Read this file before emitting any label, and copy each `name` value verbatim** — see Critical Label Rules below. If this file is missing or unreadable, skip label application and note in your triage comment that "Labels could not be applied due to a data loading error."

### Set the GitHub Issue Type

Classify every issue as exactly one of these GitHub issue types and use the `set-issue-type` safe output to apply it:

- **Bug** — Unexpected or incorrect behavior, regressions, errors, failed deployments, or behavior that does not match the documented contract.
- **Feature** — Feature requests for new user-facing capabilities, resources, variables, outputs, integrations, or enhancements to existing behavior.
- **Task** — Concrete maintenance, documentation, testing, CI, refactoring, investigation, or other actionable work that is neither a defect nor a feature request. **This is also where usage questions, feedback, and clarification requests go** — there is no `Question` issue type.

**These three are the only values `set-issue-type` accepts.** Emitting anything else — `Question`, `Documentation`, `Security`, `Enhancement` — is rejected with *"Issue type X is not in the allowed list"* and the run fails with no type applied.

The repository's **labels** are a richer taxonomy than the issue types, and they do not map one-to-one. A repo carries `Type: Question/Feedback :raising_hand:`, `Type: Documentation :page_facing_up:`, `Type: Security Bug :lock:` and more, but none of those is an issue type. Label such an issue with whichever `Type: …` label fits **and** give it the closest of the three issue types:

| The issue is | Label | Issue type |
|---|---|---|
| a usage question or feedback | `Type: Question/Feedback` | **Task** |
| a documentation gap | `Type: Documentation` | **Task** |
| a security defect | `Type: Security Bug` | **Bug** |
| a CI or workflow problem | `Type: CI` | **Task** |

Choose the single best fit from the issue's primary intent. Do not create or use any other issue type.

**Always emit `set-issue-type` with your chosen type.** There is no "already correct, skip it" case to judge: applying the type an issue already has is a harmless no-op, and re-applying it costs nothing. Emitting unconditionally is what makes this reliable.

Do not decide this from the `Type: …` **labels** or from the **`### Issue Type?`** field in the issue body. Neither is the native issue type — the labels are a separate system, and the body field is free text the reporter chose. An issue can carry `Type: Bug :bug:` and a body saying `Bug` while its native type is unset, which is the normal state of any issue triaged before issue types existed.

`/tmp/gh-aw/agent/issue-type.txt` holds the issue's current native type — one line, either `Bug`, `Feature`, `Task`, `NONE`, or `UNKNOWN`. It exists because your issue-reading tool does not return the type at all. It is context, not a gate: read it only if you intend to mention the previous value, and if you do, quote it exactly as the file reads. Never describe a type as already set unless that file literally says so.

Issue types are independent of labels, so continue with label analysis after setting the type.

Analyse the issue content and attach the most appropriate labels from the repository's existing label set. Apply **all** labels that are relevant.

### Suggested label mapping

Use the issue content to determine the most appropriate labels, but only apply labels that exist in the repository's label set.

The `name` values below are illustrative. Match on the *concept*, then emit the label name exactly as it appears in `repo-labels.json`.

| Clue in issue | Concept to match in the repo label set |
|---|---|
| Unexpected behavior, error, failed `terraform apply`, broken module output | the "Type: Bug" label |
| Request for a new capability, new variable, new resource support, or enhancement to the module | the "Type: Feature Request" label |
| Usage question, "how do I...", configuration clarification, or expected behavior question | the "Type: Question/Feedback" label |
| Missing docs, unclear examples, or incorrect README content | the "Type: Documentation" label |
| The issue is a duplicate of an existing open issue | the "Type: Duplicate" label |
| The issue seems to be an AVM-specific issue rather than a module bug | the "Type: AVM" label |
| The issue is about CI/workflow/test automation rather than module behavior | the "Type: CI" label |
| The issue needs more details before triage can proceed | the "Needs: More Evidence" label |
| The issue needs maintainer follow-up or review | the "Needs: Triage" label |

### Release-state labels

AVM tracks fixes with three labels. You may request "Status: In PR" for an open confirmed fix. Only the trusted gate may generate the two release-state labels:

| State you established | Label to match |
|---|---|
| A fix for this issue exists in an **open, unmerged** PR | the "Status: In PR" label |
| Fresh selected-PR proof is `awaiting_release` | Gate generates "Status: Awaiting Release To Be Cut"; no closure |
| Fresh selected-PR proof is `released` and no veto applies | Gate generates "Status: Fixed" alongside completed closure |
| Release membership is `unknown`, missing, failed, or incomplete | Neither release-state label; leave the issue open and explain the uncertainty |

AVM defines "Status: Awaiting Release To Be Cut" as *"This is fixed in the main branch but not in the latest release, will be fixed with next release cut"*. It is the state that keeps an issue open and visible to whoever cuts the next release, which is why an unreleased fix is labelled rather than closed.

Never emit either reserved release label in `add-labels`, even when the initial proof is positive. Submit the exact fixing PR in the mandatory comment's typed decision instead.

### Critical Label Rules

- **`repo-labels.json` is the only authoritative source of label names. Copy the `name` field byte-for-byte.** Label names in this repository embed literal emoji shortcodes such as `:heavy_plus_sign:`. Never render a shortcode into a Unicode emoji, never re-order or re-space a name, and never reconstruct a name from memory or from the table above. `Type: Feature Request ➕` is *not* the same label as `Type: Feature Request :heavy_plus_sign:` and will be rejected.
- **`add-labels` is atomic: if any one name in the batch does not exist, the entire batch is discarded** and the issue receives no labels at all. Verify every name against `repo-labels.json` before emitting.
- **`add-labels` requires at least one label. Never emit it with an empty list** — `{"type": "add_labels", "labels": []}` is rejected with "No labels provided" and fails the run. When the issue already carries every label it needs, the correct action is to not call `add-labels` at all and to say so in one line in the triage comment. This is the opposite of `set-issue-type`, which you emit on every run: re-applying a type is a harmless no-op, whereas an empty label batch is an error.
- Never remove labels that already exist on the issue.
- **In your triage comment, only list and justify the labels you are *adding* in this run. Do not mention, list, or re-justify labels that were already present on the issue** — the maintainer can already see those, so repeating them is noise.
- Only add labels that already exist in the repository's label set.
- Do not invent new labels.
- Use the `add-labels` safe output to attach labels to the issue. Listing label names in the comment body does NOT apply them.
- If the issue appears to be a duplicate, only apply `duplicate` if that label exists in the repository's label set.

---

## Step 4: Discover Related PRs and Check for Existing Fixes

Before investigating a new fix, determine whether a PR or release already addresses the issue. Do not assume that the absence of a GitHub development link means no PR exists: contributors often omit closing keywords.

### Deterministic PR Candidate Contracts (read this first)

A pre-agent step has already fetched PR candidate evidence, validated it against strict schema, count, and cross-file contracts, and written two files:

- `/tmp/gh-aw/agent/pr-candidate-status.json` — the small status and count contract.
- `/tmp/gh-aw/agent/pr-candidate-screening-index.json` — the compact inventory-screening index.

**Read them before doing anything else in Step 4** (additional candidate-specific `jq` selectors are allowed):

```bash
jq '{loaded,complete,success,errors,candidate_count,open_inventory_count,merged_inventory_count,required_inspection_count,required_inspection_numbers,exact_required_inspection_count,exact_required_inspection_numbers,timeline_required_inspection_count,timeline_required_inspection_numbers,commit_required_inspection_count,commit_required_inspection_numbers,screening_index_path,index_version}' /tmp/gh-aw/agent/pr-candidate-status.json
jq '{candidate_count,open_inventory_count,merged_inventory_count,required_inspection_count,required_inspection_numbers,inventory_only_count:(.open_inventory_screening | length),plausible_numbers:[(.required_inspection + .open_inventory_screening)[] | select((.open_inventory or .merged_inventory) and .lexical_relevance.plausible) | .number]}' /tmp/gh-aw/agent/pr-candidate-screening-index.json
jq -c '.required_inspection[] | {number,title,sources,url,state,draft,merged,body_excerpt,file_names,open_inventory,merged_inventory,lexical_relevance}' /tmp/gh-aw/agent/pr-candidate-screening-index.json
jq -c '.open_inventory_screening[] | {number,title,sources,url,state,draft,merged,body_excerpt,file_names,open_inventory,merged_inventory,lexical_relevance}' /tmp/gh-aw/agent/pr-candidate-screening-index.json
```

You do not have to validate these files or reconcile their counts — schema, count, and status-versus-index agreement were all checked before you started. If any of it failed, the rendered line at `/tmp/gh-aw/agent/triage-screening-status.md` says so in place of the counts, and that is your signal to apply the evidence veto described below. Never parse a copied terminal/UI capture or a displayed/truncated rendering. **Visible output ending early is not evidence of truncation or failure.** Report a parser or API error only when a direct-path `jq` parse actually fails or the rendered status line says the contracts did not pass.

The file is produced by fixed `gh api`/GraphQL calls (not the model), so it deterministically covers, across **all PR states with no date limit**:

- Timeline cross-references on the issue, **including non-closing mentions** (`source: timeline_cross_reference`).
- Exact `#<issue-number>` and repository-qualified (`owner/repo#<issue-number>`) matches in PR titles (`issue_number_search_title`), bodies (`issue_number_search_body`), and PR/issue comments (`issue_number_search_comment`).
- Commits whose message contains `#<issue-number>` or a qualified ref, mapped back to their associated PR — tagged `commit_body_refs` when the commit message uses a `Refs #<issue-number>` / `Fixes #<issue-number>` / `Closes #<issue-number>` / `Resolves #<issue-number>` style line, or `commit_message_reference` for any other mention. This is the only reliable way to catch a reference that lives in a commit body of an **open, unmerged** PR rather than in the PR's own title/body — those commits are not on the default branch and GitHub's commit search does not fully index commit bodies, so this cannot be found by ad-hoc searching alone.
- A paginated inventory of **every currently open PR** (`open_pr_inventory`). The screening index bounds each body excerpt to 280 characters and each filename list to 12 entries, with an explicit truncation flag.
- An inventory of the **25 most recently merged PRs from the last 180 days** (`merged_pr_inventory`), bounded the same way. This is what lets you recognise that an issue was already fixed on the default branch when nothing in the issue references the fixing PR. A merged PR only enters `required_inspection` when the issue references it; otherwise it is inventory you must still screen.

Every candidate appears exactly once in the screening index: candidates carrying any exact, timeline, or commit source are in `required_inspection`; inventory-only candidates are in `open_inventory_screening`. An open required candidate has `open_inventory: true` (and a merged one `merged_inventory: true`), so it counts toward both required inspection and inventory screening without being duplicated between arrays.

The index also supplies deterministic lexical discovery signals. It normalizes nontrivial issue/PR title, body, and filename identifiers, removes common/template words, singularizes simple plurals, and scores bounded overlaps with fixed weights. `lexical_relevance.plausible: true` makes full inspection mandatory, but neither that boolean nor its score proves relevance, a fix, or a shared root cause.

Complete **both phases**, never skipping or sampling:

1. **Required-inspection phase:** Fully inspect every PR in `required_inspection`, including its real diff, complete changed-file list, commits, tests/checks, status, base branch, and review discussion. Exact references, timeline links, and commit mentions are candidates, never proof.
2. **Inventory screening phase:** Screen every inventory candidate, open and merged. Required candidates with `open_inventory: true` or `merged_inventory: true` are screened by their mandatory full inspection; screen every entry in `open_inventory_screening` from its compact title/body/file signals. Fully inspect the real PR/diff for every entry marked lexically plausible and every additional candidate that your judgment finds plausible. Record inventory-only entries found irrelevant as screened without loading full diffs. When the reported behavior does not reproduce against current default-branch source, treat `merged_pr_inventory` as the primary place to look for the change that fixed it, and name that PR rather than concluding only that it was "possibly fixed earlier".

Track two separate lists as you work. Add a PR to `screened_inventory_prs` after reading its inventory signals and deciding whether it needs full inspection. Include irrelevant inventory rows and inventory PRs you fully inspected. Add a PR to `fully_inspected_prs` only after inspecting its real diff and supporting evidence. Required and plausible PRs need full inspection; unrelated inventory-only rows do not.

For example, an inventory of 47 PRs may require only three full inspections. After doing that work, `screened_inventory_prs` contains all 47 numbers and `fully_inspected_prs` contains the three inspected numbers. Submitting only those three as screened leaves 44 rows unaccounted for. Finding a confirmed fix does not end inventory screening.

Read large inventories in manageable batches, such as `.open_inventory_screening[0:10][]`, then `[10:20][]`, until every row is read. Keep a brief relevance verdict for each row in your working notes. Never mark a row screened from its number alone.

The pre-rendered `/tmp/gh-aw/agent/triage-screening-status.md` reports collection counts, not your inspection work. Step 6 still requires both complete PR-number lists in `add_comment.data`. Populate them from work you actually did, never by copying the inventory or assuming a passed data contract proves inspection.

Before emitting outputs, save your intended `data` object as `/tmp/gh-aw/agent/triage-decision.json` and check for missing work:

```bash
jq --slurpfile decision /tmp/gh-aw/agent/triage-decision.json '{
  missing_inventory_screening: ([.required_inspection[], .open_inventory_screening[]] | map(select(.open_inventory or .merged_inventory) | .number) - $decision[0].screened_inventory_prs),
  missing_full_inspection: (([.required_inspection[].number] + [.open_inventory_screening[] | select(.lexical_relevance.plausible) | .number] | unique) - $decision[0].fully_inspected_prs)
}' /tmp/gh-aw/agent/pr-candidate-screening-index.json
```

This comparison finds missing declarations; it does not fill either list or prove semantic inspection. Read the missing candidates before adding their numbers. If you cannot finish, set `screening_complete: false`, retain only truthful lists, and explain the missing work. An empty result cannot override a failed collection or human-reopen veto.

Classify all fully inspected candidates using the **Fix Confidence Tiers** below and report related/partial PRs even when they have no development link. Account for each lexically plausible candidate, including those you found irrelevant, with a reason.

If the rendered status line reports that the contracts did not pass, or if a required or plausible candidate ends up not fully inspected, see **Incomplete or Failed Evidence Load or Screening** below.

### Candidate Discovery

The file above is a deterministic floor, not a ceiling — it does not replace judgment-driven searching. Run these complementary searches too, and treat every hit (from the file or from these searches) the same way: a lead requiring real inspection, never proof by itself. Do not rely on one title query or an arbitrary six-month window.

1. **Inspect existing links and timeline references** — Review PRs, commits, and releases already referenced by the issue or its comments, including the timeline entries already captured in the prefetched file.
2. **Search for the exact issue number without a date limit** — Confirm and extend the prefetched title/body/comment/commit-message matches with your own search, in case the deterministic pass hit a pagination or rate-limit ceiling (see `errors` in the file).
3. **Run several semantic PR searches** — Search open, closed, and merged PRs using:
   - Distinctive error-message fragments and symptoms.
   - Terraform resource, data source, variable, output, module, and provider names.
   - Relevant file paths and Azure resource types.
   - Likely fix language combined with the affected component, such as `fix`, `resolve`, `correct`, `validation`, or `regression`.
4. **Search default-branch history** — Search commits after the issue was created, plus earlier commits when the report may concern a fix that existed before the issue was filed. Trace promising commits back to their PR when possible.
5. **Check releases** — Read the computed per-PR release evidence described below. Release notes can support what changed, but cannot substitute for verified release membership.

Open every promising candidate — from the prefetched file and from these searches — and inspect its title, body, changed files, diff, commits, tests, review discussion, merge target, and merge status. A shared keyword, file, module, or resource is only a lead; it is not proof that the PR fixes the issue.

### Fix Confidence Tiers

Classify each candidate before taking any write action:

- **Confirmed fix:** The issue and PR describe the same observed behavior and root cause; the diff changes the affected code path in a way that resolves that behavior; tests, release notes, review discussion, or equivalent evidence support that conclusion; and the issue does not contain evidence that the problem persists after the change. A merged PR must be merged into the repository's default branch to count as an existing fix.
- **Likely related fix:** The PR changes the right area and may address the issue, but the same root cause or complete resolution cannot be proven. Mention it for maintainer review, but do not modify the PR or close the issue.
- **Related only:** The PR concerns the same component but a different behavior or root cause. It may be listed as related, but do not modify the PR or close the issue.
- **No candidate found:** Continue to Step 5.

**False-positive protection:** Never link or close based only on title similarity, shared labels, a common file, broad component overlap, or an AI-generated claim in another comment. If the issue is broader than the PR, the fix requires multiple PRs, the issue reports a new variant, or evidence conflicts, downgrade the candidate and leave the issue open.

### Incomplete or Failed Evidence Load or Screening

The rendered status line at `/tmp/gh-aw/agent/triage-screening-status.md` is the authority on whether the deterministic evidence load succeeded. Do not infer failure or truncation from how much output a terminal or UI happens to display.

The load or screening is incomplete when that rendered line reports the contracts did not pass, or when your own screening work falls short. Any unread inventory row, unfinished required inspection, or unfinished plausible inspection makes screening incomplete. In that case:

- **Continue the full read-only investigation.** Keep searching and reading issues, PRs, commits, and releases exactly as described above — an incomplete prefetch never excuses skipping analysis.
- **Conservatively block two specific write actions for this run:**
  1. Do not close the issue as `completed` under **Close an Issue That Is Already Fixed** below.
  2. Do not append `Fixes #<issue-number>` to any PR under **Link an Unlinked Fix PR** below.
- **Unrelated labels, the issue type, and the triage comment are unaffected** — continue with those native requests and the Step 6 comment. The gate also withholds both reserved release labels while collection or screening is incomplete.
- **Explain the veto in the triage comment**: state that the deterministic evidence load or your screening was incomplete and that confirmed-fix closure and PR linking were skipped this run. Never claim that evidence was truncated merely because displayed output was shortened.

This PR-evidence veto covers fix-completion, reserved release labels, and PR linking. It does **not** apply to and must never weaken the **Duplicate Closure Flow** in Step 2: duplicate closure is independent of fix-PR evidence and remains allowed when the duplicate match is conclusive, its own duplicate-search contract passed, and no human-reopen/history veto applies — even if a separately discovered fix candidate is still open or unmerged. Missing or inconclusive fix-PR evidence must never downgrade an otherwise-conclusive duplicate closure.

### Link an Unlinked Fix PR

If a PR is a **confirmed fix**, is clearly intended to resolve this issue, and its body does not already contain a closing keyword for the issue:

1. Use `update-pull-request` to append exactly this standalone line to that PR's body:

   ```
   Fixes #<issue-number>
   ```

2. Identify that PR in the typed decision with `fix_confidence: confirmed`, and include its number in `fully_inspected_prs`. The gate reports the PR-body append as authorized, not already performed.

Do not add the marker to more than one PR per run. Do not add it when the PR only partially addresses the issue, when multiple PRs are jointly required, or when confidence is below the **confirmed fix** tier. An open confirmed-fix PR may be linked, but the issue must remain open until the PR is merged. Do not perform this action at all when the **Incomplete or Failed Evidence Load or Screening** veto above is active.

### Close an Issue That Is Already Fixed

**AVM closes a module issue only once the fix is published, not when it merges.** The AVM Terraform issue-triage guide is explicit: *"Only close the issue, once the next version of the module was fully developed, tested and published."* A user consuming the module from the registry still has the bug until a release carries the fix, so merging is not resolution.

Do not judge release state from a PR body, a changelog, an earlier comment, or the age of the fix. It is computed for you.

`/tmp/gh-aw/agent/release-status.json` holds initial per-PR evidence from the validated candidate index. This is investigation context, **not an eligibility list or final authorization**:

| field | meaning |
|---|---|
| `loaded` | The shared lookup finished. `false` means unknown; `true` does not imply every PR was verified. |
| `has_release` | `false` means the complete listing contained no published stable release; `null` means the listing was unavailable. Neither proves release membership. |
| `latest_tag` / `latest_published_at` | The newest published stable release, not necessarily the release containing a particular PR. |
| `prs[].number` | The candidate PR checked against the default branch and published releases. |
| `prs[].status` / `reason` | `released`, `awaiting_release`, or `unknown`, with the reason for that result. |
| `prs[].release_tag` | A published stable release proven to contain this PR's merge result. Set only for `released`. |

Identify the fixing PR from its actual diff before consulting its release result. Release membership proves where that PR landed, not whether it fixes this issue. Never select an unrelated PR merely because its status is `released`.

Read the entry for that exact PR number. For example, after independently identifying PR #270:

```bash
jq --argjson number 270 '{loaded,has_release,latest_tag,reason,pr:([.prs[] | select(.number == $number)] | if length == 1 then .[0] else {number:$number,status:"unknown",reason:"missing_or_ambiguous_pr_evidence",release_tag:null} end)}' /tmp/gh-aw/agent/release-status.json
```

- **`released` with `loaded: true` and a nonempty `release_tag`:** The initial lookup proved that the PR's merge result is an ancestor of the default branch and that published stable release. Final verification must still succeed for this exact PR.
- **`awaiting_release` with `loaded: true`:** Initially, the merge result was on the default branch and every published stable release strictly preceded it. A release may have been published since; request fresh evaluation.
- **`unknown`, missing/duplicate entry, missing file, parse failure, or `loaded: false`:** No initial proof. This does not establish that the fix is unreleased. A PR found outside the initial index is fully eligible for fresh selected-PR verification.

The pre-step checks all stable releases newest-first and stops when one proves inclusion. It resolves each tag once, then compares exact commits using GitHub's ancestry summary. It never enumerates comparison commits or scrapes PR numbers from commit messages. Normal merges, squash merges, and GitHub rebase merges use the PR's post-merge `merge_commit_sha`; unmerged test-merge commits are rejected.

Divergent histories, missing merge commits, incomplete PR evidence, failed requests, and exhausted lookup budgets yield `unknown` unless another release proves inclusion. Cherry-picks have different commit identities; this lookup does not establish whether their contents are equivalent. Investigate any alternative fix rather than overriding unknown with a claim of equivalent content.

The lookup permits at most 200 API invocations and 180 seconds before refusing new requests; each invocation has a 20-second timeout. The paginated release listing must finish within that timeout or the lookup stays unknown. These budgets limit evidence collection, not the proof required for a positive result. No published stable release is reported separately as `has_release: false`, not as an API failure or confirmed awaiting-release state.

The file deliberately exposes no raw commit-SHA list. You may inspect commits while investigating a PR, but commit identity alone does not establish which change fixed the issue. Dates, changelogs, PR bodies, missing commit-message references, and an absent list entry never prove release membership.

For a confirmed fixing PR, submit `release_action: evaluate_fix` with that exact positive `fixing_pr` and `fix_confidence: confirmed` in `add_comment.data`. Include it in `fully_inspected_prs`, including when it is absent from the initial index. Do this even if initial release evidence is missing or unknown. Missing initial membership is not incomplete discovery; failed collection or unfinished mandatory screening still vetoes release-dependent writes.

Never submit native `close-issue` with reason `completed`, never submit either reserved release label, and never create a proof file. Those direct requests are protocol violations and cannot be rescued by a different valid decision. Model-run Git commands and initial positive results never replace fresh proof.

After your work, the trusted gate verifies that exact PR once using the same bounded positive ancestry algorithm. `released` authorizes completed closure and Fixed when no veto applies; `awaiting_release` authorizes only Awaiting Release; unknown or failed proof authorizes neither. The gate supplies the exact PR/tag closure body and reopen invitation. Native handlers post the body before closing. A tag is a proven containing release, not necessarily the first containing release.

In `findings`, explain why the PR fixes the reported behavior from its actual diff. Do not predict the final release result, narrate actions as already performed, or ask a maintainer to cut a release. Semantic relevance remains your responsibility; the gate proves release membership, not semantic truth.

Do **not** close for an open or draft PR, an unmerged branch, a merely likely match, a partial fix, conflicting evidence, a fix whose default-branch inclusion cannot be verified, or a fix that is merged but unreleased. When uncertain, leave the issue open and explain what a maintainer should verify.

---

## Step 5: Investigate and Suggest a Fix

Once you have identified what the issue is about, attempt to investigate the root cause by reading relevant source code from this repository and, if needed, compare with the canonical hub-and-spoke module.

### Investigation Guidelines

- **This repository is checked out locally at `$GITHUB_WORKSPACE` on the default branch.** Reading it with shell tools (`ls`, `cat`, `rg`, `find`) is the fastest and most reliable way to establish what the current source actually contains, and it is the required way to check whether a file, test, example, variable, or output exists. Never state that something is absent from the repository without listing the relevant directory in this run — an inherited or assumed absence is the most common way this triage publishes a false claim.
- Use the GitHub MCP tools to read files, search code, and list commits in this repository.
- Look for the specific module, file, variable, output, example, or resource referenced in the issue.
- For Terraform module issues, inspect the module implementation, variables, outputs, examples, and tests.
- If the issue seems related to Azure behavior, use the **Microsoft Docs MCP** (`microsoftdocs`) to confirm the expected behavior from official documentation.
- Where useful, compare against the conventions in the canonical hub-and-spoke VNet module
  (`Azure/terraform-azurerm-avm-ptn-alz-connectivity-hub-and-spoke-vnet`) — **unless this
  repository *is* that module** — as an example of well-structured AVM Terraform code. Reading
  other public AVM repos for reference is fine; never write to them.
- If you can identify a likely root cause or a specific file/line that may need changing, include that in your triage comment.
- Keep suggestions brief and actionable.
- If the issue is a question, feature request, or consideration rather than a bug, that is perfectly fine. Note it as such in your triage comment.
- If you cannot identify a likely fix, simply state that further investigation is needed. Do not speculate.
- Never create PRs, issues, or comments in other repos. The only permitted PR write is appending the confirmed-fix marker described in Step 4 to a PR in this repository.

---

## Step 6: Post a Triage Summary Comment

**Do not emit any safe outputs until ALL analysis steps (Steps 1–5) are complete.**

ALWAYS emit **exactly one** target-issue `add-comment`, including spam, unintelligible reports, duplicates, and no-op triage. Attach the mandatory `data` object below. On reruns, reassess from current evidence; the native handler still hides older workflow-owned triage comments.

The trusted gate replaces `body` entirely. Supply a placeholder such as `Structured triage findings submitted for trusted action evaluation.` It is never published. The gate renders requested/authorized/blocked actions, verified evidence counts and search audit, then your separate semantic findings and additional audit.

All ten `data` properties are mandatory:

| Property | What you supply |
|---|---|
| `version` | Integer `1` |
| `fixing_pr` | Exact selected PR number, or integer `0` for no selected PR |
| `fix_confidence` | `none`, `confirmed`, `related`, or `partial` |
| `release_action` | `evaluate_fix` for a confirmed fixing PR requiring release verification; otherwise `none` |
| `human_reopen_override` | Step 1's boolean conclusion, never omitted |
| `screening_complete` | Whether all required/plausible full inspections and inventory screening finished |
| `fully_inspected_prs` | Unique positive integers for every fully inspected PR; include the selected PR even outside the initial index |
| `screened_inventory_prs` | Unique positive integers for every actually screened open/merged inventory PR, including irrelevant rows and fully inspected inventory PRs; not just the full-inspection subset |
| `findings` | Concise Markdown explaining the issue, duplicate verdicts, semantic fix relevance, related/partial PRs and source-backed advice |
| `audit` | Additional sources you opened and candidate verdicts; account for every mandatory comparison, including unrelated candidates |

These lists declare your work; they do not prove you inspected or understood a diff. Never assert semantic confirmation because the release checker reports `released`.

Keep `findings` concise (aim for 1,500 characters) and factual. Include links and file references where they change the reader's next step. Report every plausible PR as confirmed, related, partial, or not relevant with a reason. Put copyable code in fenced blocks with language tags. Explain why a possible duplicate is not conclusive. Do not copy prior triage claims without rechecking current source.

Neither `findings` nor `audit` may claim that labels/type were applied, the issue was closed, a PR was linked, or a release-dependent action will succeed. Do not include computed counts or an action narrative. Those belong to the trusted renderer and subsequent native execution record.

### Duplicate Closure Flow

After the mandatory typed comment, a highly confident duplicate may still use native `close-issue` with `state_reason: duplicate`, a positive integer `duplicate_of`, and body exactly `Duplicate of #<canonical-issue-number>`. Use the Step 2 canonical-selection rule. Set `release_action: none`; never combine duplicate and release-completion requests. The gate supplies the reopen note in the triage comment and preserves the exact duplicate marker. Human-reopen and missing-history vetoes still apply; missing fix-PR proof or incomplete PR screening does not itself prevent duplicate closure.

### Example: freshly evaluate an older fixing PR

The model found PR #56 by reading its diff. It is absent from this illustrative three-row inventory. The model screened PRs #32 and #33 as irrelevant and fully inspected mandatory PR #227. The request is:

```json
{
  "type": "add_comment",
  "item_number": ${{ github.event.inputs.issue_number || github.event.issue.number }},
  "body": "Structured triage findings submitted for trusted action evaluation.",
  "data": {
    "version": 1,
    "fixing_pr": 56,
    "fix_confidence": "confirmed",
    "release_action": "evaluate_fix",
    "human_reopen_override": false,
    "screening_complete": true,
    "fully_inspected_prs": [56, 227],
    "screened_inventory_prs": [32, 33, 227],
    "findings": "- PR #56 adds the caller override to the affected assignment; its test exercises the reported input. PR #227 concerns another input and does not resolve this report.",
    "audit": "- Read PR #56 diff and tests; inspected PR #227 and its changed files. Screened #32 and #33: unrelated dependency updates."
  }
}
```

Use actual inventory/inspection lists for your run, not these illustrative numbers. Do not also emit completed closure or Fixed. If fresh verification finds #56 in `v0.1.2`, the gate authorizes completion and Fixed and supplies a close body naming #56, `v0.1.2`, and the reopen invitation. If the fresh lookup fails, the comment reports unverified release membership and no automated closure. An initial positive for #227 cannot authorize #56.

For no selected fix, use `fixing_pr: 0`, `fix_confidence: none`, `release_action: none`; still populate the other fields. A missing/invalid decision produces a fallback comment, never permission inferred from prose.

---

## Safe Outputs

**Important:** Do not emit any safe outputs until ALL analysis steps (Steps 1–5) are complete.

**Every issue safe output in this run must carry the target issue number.** On a manual rerun there is no issue in the event context, so a call that omits the number is rejected with "No issue/PR number available" and that label or type is silently lost while the comment still posts and looks correct. The number for this run is **#${{ github.event.inputs.issue_number || github.event.issue.number }}**, and it is also on disk at `/tmp/gh-aw/agent/issue-number.txt`.

Every issue safe output carries it, in every combination — never only the first call, and never only the comment:

```json
{"type": "add_labels", "item_number": ${{ github.event.inputs.issue_number || github.event.issue.number }}, "labels": ["bug"]}
{"type": "set_issue_type", "issue_number": ${{ github.event.inputs.issue_number || github.event.issue.number }}, "issue_type": "Bug"}
{"type": "close_issue", "issue_number": ${{ github.event.inputs.issue_number || github.event.issue.number }}, "state_reason": "duplicate", "duplicate_of": 4321, "body": "Duplicate of #4321"}
```

`add-comment` and `add-labels` use `item_number`; `close-issue` and `set-issue-type` use `issue_number`. When updating a pull request, use that PR's number as `pull_request_number`. Before you emit anything, check each call you are about to make and confirm the number is present on all of them.

- If you **close the issue** as a duplicate: Use `add-comment` for the triage summary **first**, then use `close-issue` with `state_reason: duplicate`, `duplicate_of: <canonical-issue-number>`, and a body of exactly `Duplicate of #<canonical-issue-number>`. See the Duplicate Closure Flow.
- If a **confirmed fixing PR** needs release evaluation: Use the Step 6 typed `add-comment` decision with its exact number and `release_action: evaluate_fix`. Never emit native completed closure or either reserved release label; only the trusted gate may generate those.
- If the **Human Reopen Override** is active: Never use `close-issue`, regardless of duplicate or fix confidence. Continue with any non-closing outputs and explain the veto in the triage comment.
- If you find an unlinked **confirmed-fix PR**: Use `update-pull-request` with `pull_request_number`, `operation: append`, and a body of exactly `Fixes #<issue-number>`. Do not update likely or merely related candidates.
- Use `set-issue-type` with `issue_number` and exactly one of `Bug`, `Feature`, or `Task` on **every** run. Emit it unconditionally — never skip it on the grounds that the type looks already correct. Those three strings are the entire allowed list; a usage question is `Task`, not `Question`.
- If you find a **possible duplicate** but are **not highly confident** it is the same root cause: do **NOT** use `close-issue`. Use `add-comment` to flag `Possible duplicate of #N` (with the link) and leave the issue open; apply labels with `add-labels` as usual (but not `duplicate`). Reserve `close-issue` for confirmed duplicates only.
- If you **add labels AND post a comment** (most common case): Call **both** `add-labels` (to apply labels to the issue) AND `add-comment` (for the triage summary), and put `item_number` on **both** — the observed failure mode is a run that attaches the number to the comment and omits it from the labels, which loses the labels while the comment still publishes. ⚠️ Listing label names inside the comment body does NOT apply them — you MUST call `add-labels` as a separate action.
- If you **only post a comment** (no labels to add, no close): Use `add-comment` alone. Do not also emit `add-labels` with an empty list to signal "nothing to add" — omit the call entirely. The unconditional rule above applies to `set-issue-type` only.
- On a manual rerun, perform a complete fresh assessment. Use `add-comment` for the current result; the handler will mark older comments carrying this same workflow's hidden `gh-aw-workflow-id` as outdated and minimize them.

---

## Important Context

- This repository contains the Terraform code for a single AVM module.
- Issues, labels, releases, and code investigation all happen in this repository.
- All repositories are public — you can read code, search for files, and list commits using the GitHub MCP tools.
- Use the Microsoft Docs MCP (`microsoftdocs`) when you need to ground your answers in authoritative Azure guidance, especially for architecture or behavior questions.
- Never create issues, PRs, or comments in other repos, and never update a PR outside this repository.
- Be conservative when **closing** duplicates: close only when you are highly confident two issues share the same root cause. False positives (wrongly closing a valid issue) are much worse than false negatives. When unsure, downgrade to a *Possible duplicate* and link it instead of closing. Detection, by contrast, should be thorough — always surface candidates you find, even ones you do not close.
- Apply the same conservative standard to existing fixes. Only append `Fixes #N` or close as completed when the PR-to-issue relationship is directly supported by the issue details and the actual code change.
- A person's reopen after this workflow closed an issue always takes precedence over the agent's duplicate and existing-fix conclusions. Once detected in the timeline, leave the issue open for human review on every later run.
- When composing your triage comment, never reproduce `@mentions` from the issue body or linked content.
- This workflow is in **early stages** and is **AI-generated**. The trusted renderer supplies the automated-triage disclaimer on every comment.
