#!/usr/bin/env python3
"""Memory.parse (the Performance `footprint` reply) against /usr/bin/footprint's own text table.

Each case is one `footprint -f bytes -j FILE -p PID` run, so the JSON the app parses and the text
table printed by the same run describe the same sample:
  * fixtures/footprint-webcontent.{json,txt}: captured from a Tilr WebContent process (WebKit
    malloc, graphics, JS VM Gigacage and JIT categories present);
  * a live run on a child process of this test (the tool works without privileges for our own processes).
The text table's Dirty column per category gives malloc / graphics / js / jit / other, its
Reclaimable column summed gives reclaimable, `phys_footprint:` gives footprint.
"""
import json
from pathlib import Path
import re
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
source = (root / 'Sources/Tilr/Memory.swift').read_text()
parse = source[source.index('    /// `footprint -j` categories'):source.index('    // MARK: squeeze')]

NAMES = {'WebKit malloc': 'malloc', 'Owned physical footprint (unmapped) (graphics)': 'graphics',
         'JS VM Gigacage': 'js', 'JS JIT generated code': 'jit'}


def expected(text):
    """The first table of the text report: categories by Dirty, Reclaimable summed, phys_footprint."""
    categories = dict.fromkeys(['malloc', 'graphics', 'js', 'jit', 'other'], 0)
    reclaimable = 0
    row = re.compile(r'^\s*(\d+) B\s+(\d+) B\s+(\d+) B\s+(\d+)\s+(.+?)\s*$')
    for line in text.splitlines():
        if line.rstrip().endswith('TOTAL'):
            break
        match = row.match(line)
        if not match:
            continue
        dirty, _, reclaim, _, name = match.groups()
        categories[NAMES.get(name, 'other')] += int(dirty)
        reclaimable += int(reclaim)
    footprint = int(re.search(r'phys_footprint: (\d+) B', text).group(1))
    return {'footprint': footprint, 'reclaimable': reclaimable, 'categories': categories}


fixture = r'''
import Foundation
enum Memory {
    struct Target { let pid: pid_t; let role: String; let scope: String }
    struct Failure: LocalizedError { let message: String; var errorDescription: String? { message } }
''' + parse + r'''
}
let data = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
let pid = pid_t(CommandLine.arguments[2])!
let rows = try Memory.parse(data, targets: [Memory.Target(pid: pid, role: "webcontent", scope: "page"),
                                            Memory.Target(pid: 999_999, role: "tilr", scope: "app")])
precondition(rows.count == 1, "a target the report does not cover is left out")
do {
    _ = try Memory.parse(data, targets: [Memory.Target(pid: 999_999, role: "tilr", scope: "app")])
    preconditionFailure("no covered target must throw")
} catch is Memory.Failure {}
print(String(decoding: try JSONSerialization.data(withJSONObject: rows[0], options: .sortedKeys), as: UTF8.self))
'''


def check(label, json_path, text, pid, binary):
    out = subprocess.run([binary, str(json_path), str(pid)], check=True, capture_output=True, text=True).stdout
    row = json.loads(out)
    want = expected(text)
    assert row['pid'] == pid and row['role'] == 'webcontent' and row['scope'] == 'page', row
    for key in ('footprint', 'reclaimable', 'categories'):
        assert row[key] == want[key], f'{label} {key}: parsed {row[key]} != table {want[key]}'
    print(f'{label}: footprint {row["footprint"]}, reclaimable {row["reclaimable"]}, {row["categories"]}')
    return row


with tempfile.TemporaryDirectory(prefix='tilr-footprint-') as directory:
    program = Path(directory) / 'parse.swift'
    program.write_text(fixture)
    binary = Path(directory) / 'parse'
    subprocess.run(['/usr/bin/swiftc', '-O', '-o', str(binary), str(program)], check=True)

    fixtures = root / 'scripts/fixtures'
    captured = json.loads((fixtures / 'footprint-webcontent.json').read_text())
    row = check('fixture (WebContent)', fixtures / 'footprint-webcontent.json',
                (fixtures / 'footprint-webcontent.txt').read_text(), captured['processes'][0]['pid'], binary)
    assert all(row['categories'][key] > 0 for key in ('malloc', 'graphics', 'js', 'jit', 'other')), row

    child = subprocess.Popen(['/bin/sleep', '30'])
    try:
        live = Path(directory) / 'live.json'
        text = subprocess.run(['/usr/bin/footprint', '-f', 'bytes', '-j', str(live), '-p', str(child.pid)],
                              check=True, capture_output=True, text=True).stdout
        check('live (/bin/sleep)', live, text, child.pid, binary)
    finally:
        child.kill()

print('Footprint parser passed: categories, reclaimable and phys_footprint match the text table')
