"""The import gate needs the source job's Zig toolchain."""
from pathlib import Path
import re
import unittest

class ImportsCI(unittest.TestCase):
    def test_import_gate_runs_in_source_job(self):
        workflow = Path('.github/workflows/ci.yml').read_text()
        source = re.search(r'^  source:\n(.*?)(?=^  [a-z][a-z-]*:|\Z)', workflow, re.M | re.S).group(1)
        self.assertIn('mlugg/setup-zig@', source)
        self.assertIn('run: zig build check-imports', source)
        self.assertEqual(workflow.count('run: zig build check-imports'), 1)

if __name__ == '__main__':
    unittest.main()
