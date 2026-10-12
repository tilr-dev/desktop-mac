#!/usr/bin/env python3
"""Exercise the production process sampler against this process, without a GUI or WebKit host."""
import os
from pathlib import Path
import subprocess
import tempfile

source = (Path(__file__).resolve().parents[1] / 'Sources/Tilr/Debug.swift').read_text()
source = source[source.index('final class ProcessSampler {'):len(source)]
checks = r'''
let sampler = ProcessSampler()
let pid = getpid()
let first = sampler.read(pid, name: "test", at: 0)!
let start = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
while clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - start < 200_000_000 {}
let second = sampler.read(pid, name: "test", at: 200)!
precondition(!first.cpuReady && second.cpuReady)
precondition(second.rss > 0 && second.cpuSeconds > first.cpuSeconds)
precondition(second.cpu > 10 && second.cpu < 150, "Expected <= one busy core: \(second.cpu)")
sampler.retainPIDs([])
precondition(!sampler.read(pid, name: "test", at: 201)!.cpuReady)
print("Native sampler passed: cpu=\(second.cpu)%, footprint=\(second.rss)")
'''
with tempfile.TemporaryDirectory(prefix='tilr-performance-') as directory:
    path = Path(directory) / 'sampler.swift'
    path.write_text('import AppKit\nimport Darwin\nimport WebKit\n' + source + checks)
    subprocess.run(['/usr/bin/swift', str(path)], check=True,
                   env={**os.environ, 'CLANG_MODULE_CACHE_PATH': directory + '/cache'})
