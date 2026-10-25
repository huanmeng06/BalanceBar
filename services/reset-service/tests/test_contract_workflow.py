from copy import deepcopy
from pathlib import Path
import sys
import unittest

import json
import jsonschema
import yaml

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from service import document, instant, validate_public

ROOT = Path(__file__).resolve().parents[1]


class ContractTests(unittest.TestCase):
    def setUp(self):
        self.schema = json.loads((ROOT / 'schema.json').read_text())
        self.validator = jsonschema.Draft202012Validator(self.schema, format_checker=jsonschema.FormatChecker())

    def test_schema_and_example(self):
        jsonschema.Draft202012Validator.check_schema(self.schema)
        example = json.loads((ROOT / 'example.json').read_text())
        self.validator.validate(example)
        validate_public(example)

    def test_all_statuses_and_non_deadline_rule(self):
        for status in ['none', 'error', 'uncertain']:
            doc = document(instant('2026-10-25T05:50:00Z'), status, verified=status != 'error')
            self.validator.validate(doc)
            bad = deepcopy(doc)
            bad['observation']['deadline_at'] = '2026-10-25T07:00:00Z'
            self.assertFalse(self.validator.is_valid(bad))

    def test_deadline_requires_identity_evidence_method_and_time(self):
        example = json.loads((ROOT / 'example.json').read_text())
        for field in ['deadline_at', 'evidence', 'method']:
            bad = deepcopy(example)
            bad['observation'][field] = None
            self.assertFalse(self.validator.is_valid(bad))
        example['signal'] = None
        self.assertFalse(self.validator.is_valid(example))

    def test_workflow_is_opt_in_and_separates_permissions(self):
        workflow = yaml.safe_load((ROOT.parents[1] / '.github/workflows/reset-service.yml').read_text())
        collect = workflow['jobs']['collect']
        guard = collect['if']
        for constraint in ["RESET_SERVICE_ENABLED == 'true'", "github.event_name == 'schedule'",
                           "github.event_name == 'workflow_dispatch'", 'repository.default_branch']:
            self.assertIn(constraint, guard)
        self.assertEqual(collect['permissions'], {'contents': 'write'})
        self.assertEqual(workflow['jobs']['publish']['permissions'], {'pages': 'write', 'id-token': 'write'})
        self.assertNotIn('secrets.', json.dumps(workflow['jobs']['test']))
        self.assertFalse(workflow['concurrency']['cancel-in-progress'])
        self.assertNotIn('pull_request_target', json.dumps(workflow))


if __name__ == '__main__':
    unittest.main()
