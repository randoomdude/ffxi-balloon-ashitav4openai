"""Build a complete addon archive without copying local settings or Git data."""
from pathlib import Path
import hashlib
import re
import zipfile

ROOT = Path(__file__).resolve().parent.parent
FILES = ('Balloon.lua', 'cinematic.lua', 'defaults.lua', 'defines.lua',
         'helpers.lua', 'theme.lua', 'ui.lua', 'tests.lua', 'LICENSE',
         'readme.md', 'CHANGELOG.md', 'CREDITS.md')
DIRECTORIES = ('gdifonts', 'portraits', 'themes', 'wlibs')

def build():
    source = (ROOT / 'Balloon.lua').read_text(encoding='utf-8')
    version = re.search(r"addon.version\s*=\s*'([^']+)'", source).group(1)
    assert re.fullmatch(r'[A-Za-z0-9.-]+', version), 'Invalid version'
    assert (ROOT / 'gdifonts' / 'include.lua').is_file(), 'Initialize the gdifonts submodule first'
    members = [ROOT / name for name in FILES]
    for directory in DIRECTORIES:
        members.extend(p for p in (ROOT / directory).rglob('*')
                       if p.is_file() and '.git' not in p.parts
                       and p.name not in ('.git', '.gitignore', '.gitattributes', '.gitmodules'))
    for member in members:
        assert member.is_file(), f'Missing release file: {member.name}'
    dist = ROOT / 'dist'
    dist.mkdir(exist_ok=True)
    archive = dist / f'balloon-{version}.zip'
    with zipfile.ZipFile(archive, 'w', zipfile.ZIP_DEFLATED) as target:
        for member in sorted(set(members)):
            target.write(member, 'balloon/' + member.relative_to(ROOT).as_posix())
    with zipfile.ZipFile(archive) as target:
        assert target.testzip() is None
        names = target.namelist()
        assert all(name.startswith('balloon/') for name in names)
        assert all('/.git' not in name and '/config/' not in name for name in names)
        for name in FILES:
            assert 'balloon/' + name in names
        assert 'balloon/gdifonts/include.lua' in names
    digest = hashlib.sha256(archive.read_bytes()).hexdigest()
    (dist / (archive.name + '.sha256')).write_text(f'{digest}  {archive.name}\n', encoding='utf-8')
    print(f'Built {archive.name}: {len(names)} files, {archive.stat().st_size} bytes')
    return archive

if __name__ == '__main__':
    build()
