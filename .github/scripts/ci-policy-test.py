#!/usr/bin/env python3
import copy
import importlib.util
import unittest
import sys
from unittest.mock import patch
sys.dont_write_bytecode = True
from pathlib import Path


def load(name):
    spec = importlib.util.spec_from_file_location(name, Path(__file__).with_name(name + '.py'))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


scope = load('ci-scope')
gate = load('ci-merge-gate')


class PolicyTests(unittest.TestCase):
    def test_fast_scope(self):
        for path in ('docs/development.md', 'CONTRIBUTING.md'):
            self.assertEqual(scope.classify([('M', path)]), (False, False, False))
        for status, path in [('M', 'Sources/new.swift'), ('A', 'Tests/new.swift'),
                             ('M', '.github/workflows/build-and-test.yml'), ('M', 'Resources/lang/en.json'),
                             ('M', 'BalanceBar.xcodeproj/project.pbxproj'), ('M', 'unknown'),
                             ('D', 'docs/old.md'), ('T', 'README.md'), ('A', 'scripts/new.sh')]:
            self.assertEqual(scope.classify([(status, path)]), (True, True, path.startswith(('Tests/', 'BalanceBar.xcodeproj/'))))
        self.assertEqual(scope.classify([('D', 'old.swift'), ('A', 'docs/new.md')]), (True, True, False))

    def test_gate_matrix(self):
        ready = {'state': 'open', 'draft': False, 'head': {'sha': 'new'}, 'base': {'sha': 'base'}}
        results = {'scope': 'success', 'full': 'success', 'version': 'skipped'}
        self.assertTrue(gate.verdict('pull_request', ready, ready, results, False)[0])
        for state in ('failure', 'cancelled', 'skipped', 'missing', 'queued', 'in_progress'):
            with self.subTest(state=state):
                self.assertFalse(gate.verdict('pull_request', ready, ready, dict(results, full=state), False)[0])
                self.assertFalse(gate.verdict('pull_request', ready, ready, dict(results, scope=state), False)[0])
        draft = dict(ready, draft=True)
        for event_pr, live in ((draft, draft), (draft, ready), (ready, draft)):
            self.assertFalse(gate.verdict('pull_request', event_pr, live, results, False)[0])
        for ref in ('head', 'base'):
            stale = copy.deepcopy(ready)
            stale[ref]['sha'] = 'old'
            self.assertFalse(gate.verdict('pull_request', stale, ready, results, False)[0])
        self.assertFalse(gate.verdict('pull_request', ready, dict(ready, state='closed'), results, False)[0])
        self.assertFalse(gate.verdict('pull_request', ready, ready, results, True)[0])
        self.assertTrue(gate.verdict('pull_request', ready, ready, dict(results, version='success', full='skipped'), True)[0])
        # dispatch cannot receive a version waiver or a PR-named credential.
        self.assertFalse(gate.verdict('workflow_dispatch', None, None, dict(results, full='skipped', version='success'), True)[0])
        self.assertTrue(gate.verdict('workflow_dispatch', None, None, results, False)[0])

    def test_immediate_gate_waits_for_same_attempt(self):
        pr = {'number': 499, 'state': 'open', 'draft': False,
              'head': {'sha': 'new'}, 'base': {'sha': 'base'}}
        scope_job = {'name': 'CI repository checks and PR scope', 'conclusion': 'success', 'status': 'completed'}
        full_name = 'Full CI (CLI, probes and serial XCTest)'
        pending = {'jobs': [scope_job, {'name': full_name, 'conclusion': None, 'status': 'queued'}]}
        complete = {'jobs': [scope_job, {'name': full_name, 'conclusion': 'success', 'status': 'completed'},
                               {'name': 'Pre-Liquid-Glass artifact smoke', 'conclusion': 'failure', 'status': 'completed'}]}
        env = {'GITHUB_REPOSITORY': 'owner/repo', 'GITHUB_RUN_ID': '123', 'GITHUB_RUN_ATTEMPT': '2'}
        with patch.dict(gate.os.environ, env), patch.object(gate, 'api', side_effect=[pr, pending, pr, complete]) as api_mock, \
             patch.object(gate.subprocess, 'check_output', return_value='full\n'), patch.object(gate.time, 'sleep') as sleep:
            ok, _, results = gate.wait_for_evidence({'pull_request': pr}, 'pull_request')
            self.assertTrue(ok)
            self.assertEqual(results['smoke'], 'failure')  # advisory behavior retained
            sleep.assert_called_once_with(15)
            self.assertIn('/runs/123/attempts/2/jobs?', api_mock.call_args_list[1].args[0])
        for state in ('failure', 'cancelled', 'skipped'):
            failed = {'jobs': [scope_job, {'name': full_name, 'conclusion': state, 'status': 'completed'}]}
            with patch.dict(gate.os.environ, env), patch.object(gate, 'api', side_effect=[pr, failed]), \
                 patch.object(gate.subprocess, 'check_output', return_value='full\n'):
                self.assertFalse(gate.wait_for_evidence({'pull_request': pr}, 'pull_request')[0])

        for state in ('cancelled', 'skipped'):
            incomplete = copy.deepcopy(complete)
            incomplete['jobs'][-1]['conclusion'] = state
            with patch.dict(gate.os.environ, env), patch.object(gate, 'api', side_effect=[pr, incomplete]), \
                 patch.object(gate.subprocess, 'check_output', return_value='full\n'):
                self.assertFalse(gate.wait_for_evidence({'pull_request': pr}, 'pull_request')[0])


unittest.main()
