import hashlib
import importlib.util
from pathlib import Path
import subprocess
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / 'check_upstream_protocol.py'
spec = importlib.util.spec_from_file_location('upstream_check', SCRIPT)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class ProtocolDriftTest(unittest.TestCase):
    def test_drift_and_oracle_mismatch_are_reported_without_rewriting_sources(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            subprocess.run(['git', 'init', '-q', str(root)], check=True)
            path = root / 'server/src/core/pure-sign.js'
            path.parent.mkdir(parents=True)
            path.write_text('original')
            subprocess.run(['git', '-C', str(root), 'add', '.'], check=True)
            subprocess.run(['git', '-C', str(root), '-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.invalid', 'commit', '-qm', 'fixture'], check=True)
            revision = subprocess.check_output(['git', '-C', str(root), 'rev-parse', 'HEAD'], text=True).strip()
            digest = hashlib.sha256(path.read_bytes()).hexdigest()
            manifest = {'revision': revision, 'files': {'server/src/core/pure-sign.js': digest}}
            self.assertEqual(module.check(root, manifest, {'sourceSha256': digest})['status'], 'baseline_matches')
            path.write_text('changed')
            result = module.check(root, manifest, {'sourceSha256': digest})
            self.assertEqual(result['status'], 'review_required')
            self.assertFalse(result['signerMatchesDartOracle'])
            self.assertEqual(result['changedProtocolFiles'], ['server/src/core/pure-sign.js'])
            self.assertEqual(path.read_text(), 'changed')
            path.unlink()
            self.assertEqual(module.check(root, manifest, {'sourceSha256': digest})['status'], 'review_required')


if __name__ == '__main__':
    unittest.main()
