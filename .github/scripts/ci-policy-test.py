#!/usr/bin/env python3
import copy
import importlib.util
import unittest
import sys
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
            self.assertEqual(scope.classify([('M', path)]), (False, False))
        for status, path in [('M', 'Sources/new.swift'), ('A', 'Tests/new.swift'),
                             ('M', '.github/workflows/build-and-test.yml'), ('M', 'Resources/lang/en.json'),
                             ('M', 'BalanceBar.xcodeproj/project.pbxproj'), ('M', 'unknown'),
                             ('D', 'docs/old.md'), ('T', 'README.md'), ('A', 'scripts/new.sh')]:
            self.assertEqual(scope.classify([(status, path)]), (True, True))
        self.assertEqual(scope.classify([('D', 'old.swift'), ('A', 'docs/new.md')]), (True, True))

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


unittest.main()
