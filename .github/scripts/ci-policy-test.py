#!/usr/bin/env python3
import copy
import importlib.util
import os
from pathlib import Path
import sys
import unittest
from unittest.mock import patch
sys.dont_write_bytecode = True


def load(name):
    spec = importlib.util.spec_from_file_location(name, Path(__file__).with_name(name + '.py'))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


scope = load('ci-scope')
gate = load('ci-merge-gate')
meta = load('ci-metadata-gate')
reuse = load('ci-full-reuse')
READY = {'number': 499, 'state': 'open', 'draft': False,
         'head': {'sha': 'new'}, 'base': {'sha': 'base', 'ref': 'main'},
         'merge_commit_sha': 'merge'}
ENV = {'GITHUB_REPOSITORY': 'owner/repo', 'GITHUB_RUN_ID': '123',
       'GITHUB_RUN_ATTEMPT': '2', 'GITHUB_SHA': 'merge'}


def job(key, state='success', attempt=2, **changes):
    value = {'id': attempt * 10 + list(gate.NAMES).index(key), 'name': gate.NAMES[key],
             'run_id': 123, 'run_attempt': attempt, 'head_sha': 'new',
             'status': 'in_progress' if state in gate.WAITING else 'completed',
             'conclusion': None if state in gate.WAITING else state,
             'started_at': '2026-10-13T07:30:00Z' if attempt >= 2 else '2026-10-13T07:20:00Z',
             'completed_at': '2026-10-13T07:30:05Z' if attempt >= 2 else '2026-10-13T07:20:05Z'}
    return dict(value, **changes)


class Clock:
    def __init__(self):
        self.now = 0

    def sleep(self, seconds):
        self.now += seconds


class PolicyTests(unittest.TestCase):
    def run_gate(self, current, history=(), event=None, live=None, attempt=2, classifier='full'):
        clock = Clock()
        calls = []
        event = event or {'action': 'synchronize', 'pull_request': copy.deepcopy(READY)}

        def api(path, timeout=15):
            calls.append((path, timeout))
            self.assertGreater(timeout, 0)
            self.assertLessEqual(timeout, 15)
            if '/pulls/' in path:
                return live or copy.deepcopy(READY)
            if '?filter=all' in path:
                return {'jobs': list(history), 'total_count': len(history)}
            if '/attempts/' in path and '/jobs?' not in path:
                return {'id': 123, 'head_sha': 'new', 'run_attempt': attempt,
                        'run_started_at': '2026-10-13T07:30:00Z'}
            if '/attempts/' in path:
                values = current(clock.now) if callable(current) else current
                return {'jobs': values}
            if path.endswith('/runs/123'):
                return {'id': 123, 'head_sha': 'new', 'run_attempt': attempt,
                        'event': 'pull_request', 'workflow_id': 9,
                        'path': '.github/workflows/build-and-test.yml'}
            return {'id': 123, 'head_sha': 'new'}

        with patch.dict(os.environ, dict(ENV, GITHUB_RUN_ATTEMPT=str(attempt))), \
             patch.object(gate, 'api', side_effect=api), \
             patch.object(gate.subprocess, 'check_output', return_value=classifier + '\n') as classify, \
             patch.object(gate.time, 'monotonic', side_effect=lambda: clock.now), \
             patch.object(gate.time, 'sleep', side_effect=clock.sleep):
            result = gate.wait_for_evidence(event, 'pull_request')
        return result, clock.now, calls, classify

    def test_fast_scope(self):
        for path in ('docs/development.md', 'CONTRIBUTING.md'):
            self.assertEqual(scope.classify([('M', path)]), (False, False, False))
        for status, path in [('M', 'Sources/new.swift'), ('A', 'Tests/new.swift'),
                             ('M', '.github/workflows/build-and-test.yml'), ('M', 'Resources/lang/en.json'),
                             ('M', 'BalanceBar.xcodeproj/project.pbxproj'), ('M', 'unknown'),
                             ('D', 'docs/old.md'), ('T', 'README.md'), ('A', 'scripts/new.sh')]:
            self.assertEqual(scope.classify([(status, path)]),
                             (True, True, path.startswith(('Tests/', 'BalanceBar.xcodeproj/'))))
        self.assertEqual(scope.classify([('D', 'old.swift'), ('A', 'docs/new.md')]), (True, True, False))

    def test_draft_does_not_publish_a_required_merge_gate(self):
        # A skipped job named "PR merge gate" can satisfy a required check.
        # Run a small successful Draft-named job instead. GitHub displays raw
        # expression strings for skipped jobs with dynamic names.
        workflow = (Path(__file__).resolve().parent.parent / 'workflows' /
                    'build-and-test.yml').read_text(encoding='utf-8')
        gate_job = workflow.split('\n  merge-gate:\n', 1)[1]
        draft_expr = ("(needs.scope.outputs.draft == 'true' || (needs.scope.result == 'skipped' "
                      "&& github.event.pull_request.draft))")
        name_line = next(line for line in gate_job.splitlines()
                         if line.strip().startswith('name: ${{'))
        self.assertIn(draft_expr + " && 'Draft merge gate inactive (not required)'", name_line)
        self.assertIn("'PR merge gate'", name_line)
        self.assertIn("- name: Draft status only (not a merge credential)", gate_job)
        self.assertIn("if: ${{ github.event_name == 'pull_request' && " + draft_expr + " }}", gate_job)
        # Never skipped (skipped satisfies a required check); cancel still cancels.
        job_header = gate_job.split("\n    steps:", 1)[0]
        self.assertIn("\n    needs: scope\n", job_header)
        self.assertIn("\n    if: ${{ !cancelled() }}\n", job_header)
        self.assertNotIn('always()', next(line for line in job_header.splitlines()
                                          if line.startswith('    if:')))
        # The gate credential script must NEVER run in Draft, even when the
        # draft PR is converted from an earlier Ready with a green Full.
        self.assertIn("(!" + draft_expr + " && !(", gate_job)
        draft = copy.deepcopy(READY)
        draft['draft'] = True
        accepted, _ = gate.verdict(
            'pull_request', draft, draft,
            {'scope': 'success', 'full': 'success', 'version': 'skipped'}, False)
        self.assertFalse(accepted)

    def test_lanes_follow_live_draft_state_not_payload(self):
        # #549: opened(draft) and ready_for_review on one SHA within a second.
        # The newest run carried the stale Draft payload and shadowed Ready.
        workflow = (Path(__file__).resolve().parent.parent / 'workflows' /
                    'build-and-test.yml').read_text(encoding='utf-8')
        self.assertIn('draft: ${{ steps.scope.outputs.draft }}', workflow)
        self.assertIn('gh api "repos/$GITHUB_REPOSITORY/pulls/$PR_NUMBER" --jq .draft', workflow)
        before_gate = workflow.split('\n  merge-gate:\n', 1)[0]
        for line in before_gate.splitlines():
            if line.strip().startswith('if:'):
                self.assertNotIn('github.event.pull_request.draft', line)
        stale = dict(READY, draft=True)
        accepted, _ = gate.verdict('pull_request', stale, READY,
                                   {'scope': 'success', 'full': 'success'}, False)
        self.assertTrue(accepted)
        accepted, _ = gate.verdict('pull_request', READY, dict(READY, draft=True),
                                   {'scope': 'success', 'full': 'success'}, False)
        self.assertFalse(accepted)
        result, _, _, _ = self.run_gate([job('scope'), job('full'), job('smoke')],
                                        event={'action': 'opened', 'pull_request': stale})
        self.assertTrue(result[0])
        self.assertFalse(result[2]['live_draft'])
        self.assertIsNone(meta.pr_error(stale, READY))
        self.assertIsNotNone(meta.pr_error(READY, dict(READY, draft=True)))

    def test_metadata_gate_does_not_bypass_full(self):
        log = ('2026-10-13T13:12:04.0Z PASS: Full CI for event head/base\n'
               '2026-10-13T13:12:04.0Z Event head: new\n'
               '2026-10-13T13:12:04.0Z Base: main / base\n'
               '2026-10-13T13:12:04.0Z Checkout/merge SHA: merge\n')
        self.assertTrue(meta.metadata_log_matches(log, READY, 'merge'))
        self.assertFalse(meta.metadata_log_matches(log, READY, 'different-merge'))
        changed = copy.deepcopy(READY)
        changed['base']['sha'] = 'other'
        self.assertFalse(meta.metadata_log_matches(log, changed, 'merge'))
        self.assertFalse(meta.metadata_log_matches(log.replace('PASS:', 'FAIL:'), READY, 'merge'))
        self.assertFalse(meta.metadata_log_matches('Event head: new\nBase: main / base', READY, 'merge'))

    def test_metadata_selects_latest_real_validation(self):
        run = lambda i: {'id': i, 'workflow_id': 9, 'event': 'pull_request',
                         'head_sha': 'new', 'pull_requests': [{'number': 499}],
                         'status': 'completed', 'conclusion': 'success'}
        jobs = {
            20: [{'name': meta.NAMES['scope'], 'conclusion': 'success'},
                 {'name': 'PR merge gate', 'conclusion': 'success'}],
            21: [{'name': meta.NAMES['scope'], 'conclusion': 'skipped'},
                 {'name': 'PR merge gate', 'conclusion': 'success'}] +
                [{'name': meta.NAMES[key], 'conclusion': 'skipped'}
                 for key in ('full', 'version', 'smoke')],
            22: [{'name': meta.NAMES['scope'], 'conclusion': 'success'},
                 {'name': 'Draft merge gate inactive (not required)', 'conclusion': 'success'}]}
        args = (lambda i: jobs[i], 99, 9, 499, 'new')
        source, _, error = meta.metadata_source([run(20), run(21)], *args)
        self.assertEqual(source['id'], 20)
        self.assertIsNone(error)
        source, _, error = meta.metadata_source([run(20), run(21), run(22)], *args)
        self.assertEqual(source['id'], 22)
        self.assertIn('Draft', error)
        wrong = dict(run(23), head_sha='other')
        source, _, _ = meta.metadata_source([run(20), wrong], *args)
        self.assertEqual(source['id'], 20)
        failed_latest = [dict(j) for j in jobs[20]]
        failed_latest[1]['conclusion'] = 'failure'
        jobs[24] = failed_latest
        source, selected, error = meta.metadata_source([run(20), run(24)], *args)
        self.assertEqual(source['id'], 24)
        self.assertEqual(selected[1]['conclusion'], 'failure')
        self.assertIsNone(error)

        # A newly created Ready run has no jobs yet. Its older green sibling
        # must not supply the merge credential while Actions is queuing it.
        pending = dict(run(25), status='queued', conclusion=None)
        jobs[25] = []
        source, selected, error = meta.metadata_source([run(20), pending], *args)
        self.assertEqual(source['id'], 25)
        self.assertEqual(selected, [])
        self.assertIn('not yet visible', error)
        # Ready -> Draft -> Ready on the same SHA also hides the first Ready
        # run while the second Ready run has not published any jobs.
        jobs[26] = jobs[22]
        jobs[27] = []
        second_ready = dict(run(27), status='queued', conclusion=None)
        source, selected, error = meta.metadata_source(
            [run(20), run(26), second_ready], *args)
        self.assertEqual(source['id'], 27)
        self.assertEqual(selected, [])
        self.assertIn('not yet visible', error)

    def test_metadata_partial_jobs_cannot_expose_old_green(self):
        old = {'id': 20, 'workflow_id': 9, 'event': 'pull_request',
               'head_sha': 'new', 'pull_requests': [{'number': 499}],
               'status': 'completed', 'conclusion': 'success'}
        partial_lists = [
            [{'name': meta.NAMES['full'], 'conclusion': None}],
            [{'name': meta.NAMES['scope'], 'conclusion': 'skipped'}],
            [{'name': 'PR merge gate', 'conclusion': None},
             {'name': meta.NAMES['scope'], 'conclusion': 'skipped'}],
        ]
        for partial in partial_lists:
            for status in ('queued', 'in_progress', 'completed'):
                with self.subTest(jobs=partial, status=status):
                    latest = dict(old, id=21, status=status)
                    queried = []
                    def jobs(run_id):
                        queried.append(run_id)
                        self.assertEqual(run_id, 21)
                        return partial
                    source, _, error = meta.metadata_source(
                        [old, latest], jobs, 99, 9, 499, 'new')
                    self.assertEqual(source['id'], 21)
                    self.assertIsNotNone(error)
                    self.assertEqual(queried, [21])

    def test_draft_with_skipped_scope_blocks_old_ready(self):
        old = {'id': 20, 'workflow_id': 9, 'event': 'pull_request',
               'head_sha': 'new', 'pull_requests': [{'number': 499}],
               'status': 'completed', 'conclusion': 'success'}
        latest = dict(old, id=21)
        jobs = [{'name': meta.NAMES['scope'], 'conclusion': 'skipped'},
                {'name': 'Draft merge gate inactive (not required)',
                 'conclusion': 'success'}]
        source, _, error = meta.metadata_source(
            [old, latest], lambda _: jobs, 99, 9, 499, 'new')
        self.assertEqual(source['id'], 21)
        self.assertIn('Draft', error)

    def test_metadata_waits_past_missing_job_grace_while_queued(self):
        clock = Clock()
        run = lambda i, status: {'id': i, 'workflow_id': 9, 'event': 'pull_request',
                                 'head_sha': 'new', 'pull_requests': [{'number': 499}],
                                 'status': status, 'conclusion': 'success' if status == 'completed' else None}
        old_jobs = [{'id': 200, 'name': meta.NAMES['scope'], 'conclusion': 'success'},
                    {'id': 201, 'name': meta.NAMES['full'], 'conclusion': 'success'},
                    {'id': 202, 'name': meta.NAMES['smoke'], 'conclusion': 'success'},
                    {'id': 203, 'name': 'PR merge gate', 'conclusion': 'success'}]
        new_jobs = [dict(j, id=j['id'] + 100) for j in old_jobs]
        log = ('PASS: Full CI for event head/base\nEvent head: new\n'
               'Base: main / base\nCheckout/merge SHA: merge\n')
        seen = []

        def api(path):
            seen.append((clock.now, path))
            if path.endswith('/runs/123'):
                return {'event': 'pull_request', 'head_sha': 'new', 'workflow_id': 9}
            if '/pulls/' in path:
                return dict(copy.deepcopy(READY), merge_commit_sha='merge')
            if '/actions/runs?' in path:
                latest = run(21, 'queued' if clock.now < 75 else 'completed')
                return {'workflow_runs': [run(20, 'completed'), latest], 'total_count': 2}
            if '/runs/21/jobs?' in path:
                values = ([] if clock.now < 30 else
                          [{'id': 301, 'name': meta.NAMES['full'], 'conclusion': None}]
                          if clock.now < 75 else new_jobs)
                return {'jobs': values, 'total_count': len(values)}
            if '/runs/20/jobs?' in path:
                return {'jobs': old_jobs, 'total_count': len(old_jobs)}
            raise AssertionError(path)

        event = {'action': 'edited', 'changes': {'body': {'from': 'old'}},
                 'pull_request': copy.deepcopy(READY)}
        with patch.dict(os.environ, dict(ENV)), patch.object(meta, 'api', side_effect=api), \
             patch.object(meta.subprocess, 'check_output', return_value=log), \
             patch.object(meta.time, 'monotonic', side_effect=lambda: clock.now), \
             patch.object(meta.time, 'sleep', side_effect=clock.sleep):
            accepted, _, evidence = meta.metadata_gate(event)
        self.assertTrue(accepted)
        self.assertGreaterEqual(clock.now, 75)
        self.assertEqual(evidence['source_run'], 21)
        self.assertFalse(any('/runs/20/jobs?' in path for _, path in seen))

    def test_metadata_rechecks_latest_run_before_success(self):
        # Ready -> Draft -> Ready can reuse the same head SHA. A newer run
        # arriving while the old gate log is read invalidates the old result.
        clock = Clock()
        old = {'id': 20, 'workflow_id': 9, 'event': 'pull_request',
               'head_sha': 'new', 'pull_requests': [{'number': 499}],
               'status': 'completed', 'conclusion': 'success'}
        newer = dict(old, id=21, status='queued', conclusion=None)
        jobs = [{'id': 1, 'name': meta.NAMES['scope'], 'conclusion': 'success'},
                {'id': 2, 'name': meta.NAMES['full'], 'conclusion': 'success'},
                {'id': 3, 'name': meta.NAMES['smoke'], 'conclusion': 'success'},
                {'id': 4, 'name': 'PR merge gate', 'conclusion': 'success'}]
        read_count = 0

        def api(path):
            nonlocal read_count
            if path.endswith('/runs/123'):
                return {'event': 'pull_request', 'head_sha': 'new', 'workflow_id': 9}
            if '/pulls/' in path:
                return dict(copy.deepcopy(READY), merge_commit_sha='merge')
            if '/actions/runs?' in path:
                read_count += 1
                values = [old] if read_count == 1 else [old, newer]
                return {'workflow_runs': values, 'total_count': len(values)}
            if '/runs/20/jobs?' in path:
                return {'jobs': jobs, 'total_count': len(jobs)}
            if '/runs/21/jobs?' in path:
                return {'jobs': [], 'total_count': 0}
            raise AssertionError(path)

        event = {'action': 'edited', 'changes': {'body': {'from': 'old'}},
                 'pull_request': copy.deepcopy(READY)}
        log = ('PASS: Full CI for event head/base\nEvent head: new\n'
               'Base: main / base\nCheckout/merge SHA: merge\n')
        with patch.dict(os.environ, dict(ENV)), patch.object(meta, 'api', side_effect=api), \
             patch.object(meta.subprocess, 'check_output', return_value=log), \
             patch.object(meta.time, 'monotonic', side_effect=lambda: clock.now), \
             patch.object(meta.time, 'sleep', side_effect=lambda seconds: setattr(clock, 'now', clock.now + seconds)):
            accepted, reason, _ = meta.metadata_gate(event)
        self.assertFalse(accepted)
        self.assertIn('Timed out', reason)
        self.assertGreater(read_count, 2)

    def test_metadata_workflow_uses_required_name_and_real_evidence(self):
        workflow = (Path(__file__).resolve().parent.parent / 'workflows' /
                    'build-and-test.yml').read_text(encoding='utf-8')
        gate_job = workflow.split('\n  merge-gate:\n', 1)[1]
        self.assertIn("- name: Confirm prior Full gate for metadata-only edit", gate_job)
        self.assertIn("run: python3 .github/scripts/ci-metadata-gate.py", gate_job)
        self.assertNotIn('PR metadata edit (no merge credential)', gate_job)

    def test_reuse_lane_requires_a_second_evidence_check(self):
        with patch.object(gate, 'verify_reuse', return_value=(True, 'verified')):
            result, elapsed, _, _ = self.run_gate(
                [job('scope'), job('full', 'skipped'), job('reuse')], classifier='full')
        self.assertTrue(result[0])
        self.assertEqual(elapsed, 0)
        self.assertEqual(result[2]['reuse'], 'success')
        self.assertTrue(result[2]['reuse_revalidated'])

        with patch.object(gate, 'verify_reuse', return_value=(False, 'changed')):
            result, _, _, _ = self.run_gate(
                [job('scope'), job('full', 'skipped'), job('reuse')])
        self.assertFalse(result[0])
        self.assertIn('changed', result[1])

    def test_full_and_reuse_lanes_never_coexist(self):
        with patch.object(gate, 'verify_reuse', return_value=(True, 'verified')):
            result, _, _, _ = self.run_gate(
                [job('scope'), job('full'), job('reuse')])
        self.assertFalse(result[0])
        self.assertIn('both published', result[1])

        result, _, _, _ = self.run_gate(
            [job('scope'), job('full'), job('reuse', 'skipped'), job('smoke')])
        self.assertTrue(result[0])
        self.assertEqual(result[2]['full'], 'success')

    def test_reuse_identity_parser_rejects_legacy_gate_logs(self):
        old_log = ('PASS: Full CI for event head/base\n'
                   'Event head: new\nBase: main / base\n'
                   'Checkout/merge SHA: merge\n')
        with self.assertRaises(reuse.EvidenceError):
            reuse.parse_identity(reuse.normalize_log_lines(old_log))

    def test_reuse_requires_exact_pr_merge_parents(self):
        commit = {'sha': 'merge', 'parents': [{'sha': 'base'}, {'sha': 'new'}]}
        with patch.object(reuse, 'api', return_value=commit):
            reuse.verify_merge_commit('owner/repo', 'merge', 'base', 'new')
        with patch.object(reuse, 'api', return_value={
                'sha': 'merge', 'parents': [{'sha': 'base'}, {'sha': 'other'}]}):
            with self.assertRaises(reuse.EvidenceError):
                reuse.verify_merge_commit('owner/repo', 'merge', 'base', 'new')

    def test_reuse_scopes_workflow_run_lookup_to_commit_head(self):
        calls = []

        def api(path):
            calls.append(path)
            return {'workflow_runs': [], 'total_count': 0}

        with patch.object(reuse, 'api', side_effect=api):
            self.assertEqual(
                reuse.list_workflow_runs_for_head('owner/repo', 9, 'head'), []
            )
        self.assertEqual(len(calls), 1)
        self.assertIn('event=pull_request', calls[0])
        self.assertIn('head_sha=head', calls[0])

    def test_reuse_checks_each_intermediate_commit_and_aggregate(self):
        def fake_git(*args):
            if args == ('rev-list', '--reverse', 'base..head'):
                return 'c1\nc2'
            if args == ('rev-list', '--parents', '-n', '1', 'c1'):
                return 'c1 base'
            if args == ('rev-list', '--parents', '-n', '1', 'c2'):
                return 'c2 c1'
            raise AssertionError(args)

        class Result:
            returncode = 0
            stdout = 'version-only\n'
            stderr = ''

        with patch.object(reuse, 'is_ancestor', return_value=True), \
             patch.object(reuse, 'git', side_effect=fake_git), \
             patch.object(reuse.subprocess, 'run', return_value=Result()):
            self.assertEqual(reuse.validate_version_chain('base', 'head'), 2)

        def not_version(command, **_):
            result = Result()
            if command[-1] == 'c2':
                result.stdout = 'full\n'
            return result

        with patch.object(reuse, 'is_ancestor', return_value=True), \
             patch.object(reuse, 'git', side_effect=fake_git), \
             patch.object(reuse.subprocess, 'run', side_effect=not_version):
            with self.assertRaises(reuse.EvidenceError):
                reuse.validate_version_chain('base', 'head')

    def test_reuse_rejects_ambiguous_nearest_head(self):
        def fake_git(*args):
            if args == ('rev-list', '--count', 'a..current'):
                return '2'
            if args == ('rev-list', '--count', 'b..current'):
                return '2'
            raise AssertionError(args)

        with patch.object(reuse, 'is_ancestor', return_value=True), \
             patch.object(reuse, 'git', side_effect=fake_git):
            with self.assertRaises(reuse.EvidenceError):
                reuse.nearest_prior_head(
                    [{'head_sha': 'a'}, {'head_sha': 'b'}], 'current')

    def test_workflow_keeps_full_fallback_and_explicit_reuse_lane(self):
        workflow = (Path(__file__).resolve().parent.parent / 'workflows' /
                    'build-and-test.yml').read_text(encoding='utf-8')
        self.assertIn('reuse_full: ${{ steps.scope.outputs.reuse_full }}', workflow)
        self.assertIn('name: Verified prior Full reuse (version increment; no XCTest)', workflow)
        self.assertIn('python3 .github/scripts/ci-full-reuse.py "$BASE_SHA" "$HEAD_SHA" --require', workflow)
        self.assertIn("needs.scope.outputs.reuse_full != 'true' || needs.scope.outputs.force_full == 'true'", workflow)

    def test_event_routes_and_retarget_full(self):
        for changes in ({'body': {'from': ''}}, {'title': {'from': 'old'}}):
            event = {'action': 'edited', 'changes': changes, 'pull_request': READY}
            result, _, calls, classifier = self.run_gate([], event=event)
            self.assertFalse(result[0])
            self.assertIn('NO merge credential', result[1])
            self.assertEqual(calls, [])
            classifier.assert_not_called()
        for changes in ({'base': {'ref': {'from': 'other'}}}, {}, {'unknown': {}}):
            event = {'action': 'edited', 'changes': changes, 'pull_request': READY}
            result, _, _, classifier = self.run_gate(
                [job('scope'), job('full'), job('smoke')], event=event, classifier='version-only')
            self.assertTrue(result[0])
            classifier.assert_not_called()
        draft = dict(READY, draft=True)
        result, _, _, _ = self.run_gate([], event={'action': 'edited', 'changes': {'base': {}},
                                                'pull_request': draft}, live=draft)
        self.assertFalse(result[0])

    def test_ref_and_sha_identity(self):
        for ref, field in (('head', 'sha'), ('base', 'sha'), ('base', 'ref')):
            for replacement in ('changed', None):
                live = copy.deepcopy(READY)
                live[ref][field] = replacement
                result, elapsed, _, _ = self.run_gate([], live=live)
                self.assertFalse(result[0])
                self.assertEqual(elapsed, 0)
        bad_event = copy.deepcopy(READY)
        del bad_event['base']['ref']
        result, _, _, _ = self.run_gate([], event={'pull_request': bad_event})
        self.assertFalse(result[0])

    def test_scope_carry_and_current_attempt_full(self):
        result, elapsed, _, _ = self.run_gate([job('full'), job('smoke', 'failure')],
                                              history=[job('scope', attempt=1)])
        self.assertTrue(result[0])  # smoke failure is advisory
        self.assertEqual(elapsed, 0)
        self.assertTrue(result[2]['scope_reused'])
        self.assertEqual(result[2]['evidence']['scope']['attempt'], 1)
        self.assertEqual(result[2]['evidence']['full']['attempt'], 2)

    def test_failed_or_foreign_scope_never_reused(self):
        for state in ('failure', 'cancelled', 'skipped'):
            history = [job('scope', attempt=1), job('scope', state, attempt=2)]
            result, elapsed, _, _ = self.run_gate([job('full', attempt=3), job('smoke', attempt=3)],
                                                  history=history, attempt=3)
            self.assertFalse(result[0])
            self.assertEqual(elapsed, 60)
        for changes in ({'run_id': 999}, {'head_sha': 'old'}):
            result, elapsed, _, _ = self.run_gate([job('full'), job('smoke')],
                                                  history=[job('scope', attempt=1, **changes)])
            self.assertFalse(result[0])
            self.assertEqual(elapsed, 60)

    def test_copied_jobs_with_new_attempt_ids_are_not_fresh_full(self):
        original = [job(key, attempt=1) for key in ('scope', 'full', 'smoke')]
        copies = [dict(j, id=j['id'] + 100, run_attempt=2) for j in original]
        result, elapsed, _, _ = self.run_gate(copies, history=original)
        self.assertFalse(result[0])
        self.assertEqual(elapsed, 60)
        self.assertTrue(result[2]['scope_reused'])
        self.assertEqual(result[2]['evidence']['scope']['attempt'], 1)
        self.assertIn('full', result[1])
        result, _, _, _ = self.run_gate([copies[0], job('full'), job('smoke')], history=original)
        self.assertTrue(result[0])
        self.assertTrue(result[2]['scope_reused'])

    def test_current_scope_preferred_even_if_failed(self):
        result, elapsed, calls, _ = self.run_gate([job('scope', 'failure'), job('full'), job('smoke')],
                                                 history=[job('scope', attempt=1)])
        self.assertFalse(result[0])
        self.assertEqual(elapsed, 0)
        self.assertFalse(any('filter=all' in path for path, _ in calls))

    def test_old_full_and_smoke_never_reused(self):
        history = [job(key, attempt=1) for key in ('scope', 'full', 'smoke')]
        for current in ([], [job('full')]):
            result, elapsed, _, _ = self.run_gate(current, history=history)
            self.assertFalse(result[0])
            self.assertEqual(elapsed, 60)
            self.assertIn('Re-run all jobs', result[1])

    def test_queued_dependencies_do_not_start_child_missing_timer(self):
        def current(now):
            if now < 120:
                return [job('scope', 'queued')]
            if now < 240:
                return [job('scope'), job('full', 'in_progress')]
            return [job('scope'), job('full'), job('smoke')]
        result, elapsed, _, _ = self.run_gate(current)
        self.assertTrue(result[0])
        self.assertEqual(elapsed, 240)

    def test_smoke_missing_clock_starts_after_full(self):
        def current(now):
            return [job('scope'), job('full', 'in_progress' if now < 120 else 'success')]
        result, elapsed, _, _ = self.run_gate(current)
        self.assertFalse(result[0])
        self.assertEqual(elapsed, 180)
        self.assertIn('smoke', result[1])

    def test_failure_cancelled_skipped_are_not_credentials(self):
        for state in ('failure', 'cancelled', 'skipped', 'neutral', 'timed_out'):
            result, _, _, _ = self.run_gate([job('scope'), job('full', state), job('smoke')])
            self.assertFalse(result[0])
        for state in ('cancelled', 'skipped'):
            result, _, _, _ = self.run_gate([job('scope'), job('full'), job('smoke', state)])
            self.assertFalse(result[0])
        result, _, _, _ = self.run_gate([job('scope'), job('version')], classifier='version-only')
        self.assertTrue(result[0])
        result, elapsed, _, _ = self.run_gate([job('scope')], history=[job('version', attempt=1)],
                                              classifier='version-only')
        self.assertFalse(result[0])
        self.assertEqual(elapsed, 60)

    def test_dispatch_requires_scope_and_full(self):
        self.assertFalse(gate.verdict('workflow_dispatch', None, None,
                                     {'scope': 'success', 'full': 'skipped'}, False)[0])
        self.assertFalse(gate.verdict('workflow_dispatch', None, None,
                                     {'scope': 'missing', 'full': 'success'}, False)[0])


unittest.main()
