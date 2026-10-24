"""Check that the single project source entry includes every RTL file exactly once."""
import json
import re
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PROJECT = ROOT / 'elinx/AFDX_EndSystem.epr'
WRAPPER = ROOT / 'elinx/afdx_all.v'

errors = []


def fail(message):
    errors.append(message)


def main():
    document = ET.parse(PROJECT).getroot()
    source_sets = document.findall("./FileSets/FileSet[@Type='DesignSrcs']")
    if len(source_sets) != 1:
        fail('expected exactly one design source set')
        return report()
    files = source_sets[0].findall('File')
    paths = [(PROJECT.parent / item.attrib['Path'].lstrip('/')).resolve() for item in files]
    if len(paths) != 1:
        fail('project source set must list exactly one file, found %d' % len(paths))
    elif paths[0] != WRAPPER.resolve():
        fail('project source must be %s, found %s' % (WRAPPER.name, paths[0].name))
    if not WRAPPER.is_file():
        fail('missing aggregate source: ' + WRAPPER.name)
        return report()

    included = []
    saw_include = False
    for number, raw in enumerate(WRAPPER.read_text(encoding='utf-8-sig').splitlines(), 1):
        line = raw.strip()
        if not line or line.startswith('//'):
            continue
        match = re.fullmatch(r'`include\s+"([^"]+)"', line)
        if not match:
            fail('line %d is not an include or comment: %s' % (number, line))
            continue
        saw_include = True
        target = (WRAPPER.parent / match.group(1)).resolve()
        if not target.is_file():
            fail('line %d includes a missing file: %s' % (number, match.group(1)))
        included.append(target)
    if not saw_include:
        fail('aggregate source has no includes')

    expected = sorted((ROOT / 'rtl').glob('*.v'))
    names = [path.name for path in included]
    duplicates = sorted({name for name in names if names.count(name) > 1})
    if duplicates:
        fail('duplicate includes: ' + ', '.join(duplicates))
    missing = sorted(set(expected) - set(included))
    extra = sorted(set(included) - set(expected))
    if missing:
        fail('RTL files not included: ' + ', '.join(path.name for path in missing))
    if extra:
        fail('includes outside rtl/: ' + ', '.join(path.name for path in extra))
    return report()


def report():
    status = 'PASS' if not errors else 'FAIL'
    for error in errors:
        print('ERROR ' + error)
    print('CHECK %s wrapper=%s rtl_files=%d includes=%d errors=%d'
          % (status, WRAPPER.name, len(list((ROOT / 'rtl').glob('*.v'))), 24, len(errors)))
    print('RESULT check_wrapper %s checks=5 errors=%d' % (status, len(errors)))
    return 0 if not errors else 1


if __name__ == '__main__':
    raise SystemExit(main())
