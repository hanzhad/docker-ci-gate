'use strict';

// Automatically align Node runtime and test runners with container CPU quota.
if (!globalThis.__ci_runner_cgroup_applied) {
  globalThis.__ci_runner_cgroup_applied = true;

  const os = require('os');

  function getCpuQuota() {
    const envCpus = process.env.CI_CPUS;
    if (envCpus) {
      const parsed = parseFloat(envCpus);
      if (!isNaN(parsed) && parsed > 0) {
        return Math.max(1, Math.floor(parsed));
      }
    }

    try {
      const fs = require('fs');
      if (fs.existsSync('/sys/fs/cgroup/cpu.max')) {
        const content = fs.readFileSync('/sys/fs/cgroup/cpu.max', 'utf8').trim();
        const parts = content.split(/\s+/);
        const quota = parts[0];
        const period = parts[1] || '100000';
        if (quota !== 'max' && !isNaN(quota) && !isNaN(period) && Number(period) > 0) {
          const calculated = Math.floor(Number(quota) / Number(period));
          if (calculated > 0) return Math.max(1, calculated);
        }
      }
    } catch (_) {}

    return null;
  }

  const quota = getCpuQuota();
  if (quota !== null && quota > 0) {
    const origCpus = os.cpus.bind(os);
    os.cpus = function () {
      const list = origCpus();
      return list.slice(0, quota);
    };

    if (typeof os.availableParallelism === 'function') {
      os.availableParallelism = function () {
        return quota;
      };
    }
  }
}
