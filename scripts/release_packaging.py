"""Transform only unsigned staging copies; never edit completed release artifacts."""
import json
from pathlib import Path
import shutil
import subprocess

MACHO = {bytes.fromhex(x) for x in ('feedface', 'cefaedfe', 'feedfacf', 'cffaedfe', 'cafebabe', 'bebafeca', 'cafebabf', 'bfbafeca')}


def binaries(root):
    for path in sorted(root.rglob('*')):
        if path.is_symlink() or not path.is_file():
            continue
        with path.open('rb') as file:
            if file.read(4) in MACHO:
                yield path


def architectures(path):
    return subprocess.check_output(['lipo', str(path), '-archs'], text=True).split()


def thin_tree(root, arch):
    if arch not in ('arm64', 'x86_64'):
        raise ValueError('Packaging requires one architecture')
    for path in binaries(root):
        slices = architectures(path)
        if arch not in slices:
            raise ValueError(f'Missing {arch} slice: {path}')
        if slices != [arch]:
            temporary = path.with_name(path.name + '.thin')
            subprocess.run(['lipo', str(path), '-thin', arch, '-output', str(temporary)], check=True)
            temporary.chmod(path.stat().st_mode)
            temporary.replace(path)


def strip_executable(path, symbols):
    symbols.mkdir(parents=True, exist_ok=True)
    # Keep the original executable and any SwiftPM dSYM outside the shipped app.
    shutil.copy2(path, symbols / (path.name + '.unstripped'))
    subprocess.run(['strip', '-x', str(path)], check=True)


def audit(root, arch):
    for path in root.rglob('*'):
        if path.suffix == '.dSYM' or path.name in ('node_modules', '.git', '.build'):
            raise ValueError(f'Build-only files in app: {path}')
    rows = []
    for path in binaries(root):
        slices = architectures(path)
        if slices != [arch]:
            raise ValueError(f'Expected only {arch}, found {slices}: {path}')
        rows.append(dict(path=str(path.relative_to(root)), bytes=path.stat().st_size, architectures=slices))
    if not rows:
        raise ValueError('No Mach-O executables in application')
    return rows


def size_report(app, dmg, arch, output):
    files = [p for p in app.rglob('*') if p.is_file() and not p.is_symlink()]
    data = dict(architecture=arch, app_bytes=sum(p.stat().st_size for p in files),
                dmg_bytes=dmg.stat().st_size, executables=audit(app, arch))
    output.write_text(json.dumps(data, indent=2) + '\n')
    return data
