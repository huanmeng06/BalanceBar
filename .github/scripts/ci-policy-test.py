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
READY = {'number': 499, 'state': 'open', 'draft': False,
         'head': {'sha': 'new'}, 'base': {'sha': 'base', 'ref': 'main'}}
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
        name_line = next(line for line in gate_job.splitlines()
                         if line.strip().startswith('name: ${{'))
        self.assertIn("github.event.pull_request.draft && "
                      "'Draft merge gate inactive (not required)'", name_line)
        self.assertIn("'PR merge gate'", name_line)
        self.assertIn("- name: Draft status only (not a merge credential)", gate_job)
        self.assertIn("if: ${{ github.event_name == 'pull_request' && "
                      "github.event.pull_request.draft }}", gate_job)
        self.assertNotIn("    if: ${{ github.event_name != 'pull_request' || "
                         "!github.event.pull_request.draft }}\n", gate_job)
        # The gate credential script must NEVER run in Draft, even when the
        # draft PR is converted from an earlier Ready with a green Full.
        self.assertIn("!github.event.pull_request.draft && !(", gate_job)
        draft = copy.deepcopy(READY)
        draft['draft'] = True
        accepted, _ = gate.verdict(
            'pull_request', draft, draft,
            {'scope': 'success', 'full': 'success', 'version': 'skipped'}, False)
        self.assertFalse(accepted)

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
                 {'name': 'PR merge gate', 'conclusion': 'success'}],
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

    def test_metadata_workflow_uses_required_name_and_real_evidence(self):
        workflow = (Path(__file__).resolve().parent.parent / 'workflows' /
                    'build-and-test.yml').read_text(encoding='utf-8')
        gate_job = workflow.split('\\n  merge-gate:\\n', 1)[1]
        self.assertIn("- name: Confirm prior Full gate for metadata-only edit", gate_job)
        self.assertIn("run: python3 .github/scripts/ci-metadata-gate.py", gate_job)
        self.assertNotIn('PR metadata edit (no merge credential)', gate_job)

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
