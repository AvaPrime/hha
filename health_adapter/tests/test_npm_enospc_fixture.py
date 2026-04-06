import unittest

from health_adapter.domain.diagnosis import diagnose
from health_adapter.domain.models import (
    DriveStat,
    EvidenceEnvelope,
    HealthRequest,
    ToolchainConfigEvidence,
    ToolchainPaths,
)


class TestNpmEnospcFixture(unittest.TestCase):
    def test_detects_misrouted_cache(self):
        request = HealthRequest(
            device_id='dev_nexus_01',
            workspace_id='ws_system_health',
            target_toolchain='npm',
            project_path='C:\\Projects\\system_health',
            symptom='install_failed_enospc',
            mode='safe_auto_remediate',
        )

        evidence = ToolchainConfigEvidence(
            toolchain='npm',
            env_overrides={'npm_config_cache': 'D:\\Temp\\npm'},
            paths=ToolchainPaths(
                effective_cache_path='D:\\Temp\\npm',
                configured_cache_path='E:\\npm-cache',
                effective_temp_path='D:\\Temp',
            ),
            config_graph={},
        )

        envelope = EvidenceEnvelope(
            request=request,
            drive_stats={
                'D:': DriveStat(drive='D:', total_bytes=512 * 1024 * 1024, free_bytes=0),
                'E:': DriveStat(drive='E:', total_bytes=900 * 1024**3, free_bytes=850 * 1024**3),
            },
            toolchain_evidence=evidence,
        )

        diagnosis = diagnose(envelope)
        self.assertEqual(diagnosis.primary_diagnosis, 'cache_path_misrouted')
        self.assertIn('disk_exhaustion_effective_path', diagnosis.secondary_diagnoses)
        self.assertIn('env_override_conflict', diagnosis.secondary_diagnoses)


if __name__ == '__main__':
    unittest.main()

