from pathlib import Path
import zipfile, tarfile, io, os
root=Path(__file__).resolve().parents[1] / 'artifacts' / 'fixtures'
root.mkdir(parents=True,exist_ok=True)
data=root/'Design Kit'
for folder in ['Documents','Images','Code','Media']:(data/folder).mkdir(parents=True,exist_ok=True)
(data/'Documents'/'Başlangıç rehberi.md').write_text('# MacRAR Plus\n\nArşivlerini aç, incele ve güvenle çıkart.\n\n- Dosya türü filtreleri\n- Hızlı önizleme\n- Toplu işlemler\n',encoding='utf-8')
(data/'Documents'/'Product brief.txt').write_text('PROJECT ARCHIVE\nNative macOS archive workspace\n\nRelease: 2.0\n',encoding='utf-8')
(data/'Code'/'settings.json').write_text('{"theme":"system","language":"tr","local":true}\n')
(data/'Code'/'app.swift').write_text('import Foundation\nprint("Hello, archive.")\n')
(data/'Images'/'App Icon.png').write_bytes((root.parents[1]/'docs'/'icon.png').read_bytes())
(data/'literal[1].txt').write_text('literal wildcard filename')
(data/'literal1.txt').write_text('must not be selected by wildcard')
(data/'.hidden').write_text('hidden file')
(data/'empty').mkdir(exist_ok=True)
with zipfile.ZipFile(root/'Design Kit.zip','w',zipfile.ZIP_DEFLATED) as z:
    for p in data.rglob('*'):
        if p.is_file():z.write(p,p.relative_to(data.parent))
        elif not any(p.iterdir()):z.writestr(str(p.relative_to(data.parent))+'/',b'')
with zipfile.ZipFile(root/'traversal.zip','w') as z:z.writestr('../escape.txt','must never escape')
with zipfile.ZipFile(root/'absolute.zip','w') as z:z.writestr('/tmp/macrarplus-escape.txt','must never escape')
with zipfile.ZipFile(root/'link.zip','w') as z:
    e=zipfile.ZipInfo('link');e.create_system=3;e.external_attr=(0o120777<<16);z.writestr(e,'../outside')
with tarfile.open(root/'links.tar','w') as t:
    e=tarfile.TarInfo('link');e.type=tarfile.SYMTYPE;e.linkname='../outside';t.addfile(e)
(root/'broken.zip').write_bytes(b'PK\x03\x04broken archive')
with tarfile.open(root/'bundle.tar.gz','w:gz') as t:t.add(data,arcname='Design Kit',filter=lambda e: e if not e.issym() else None)
(root/'broken.tar.gz').write_bytes((root/'bundle.tar.gz').read_bytes()[:-30])
for name, dot, mode in [('plain.tar',False,'w'),('dot.tar',True,'w'),('dot.tar.gz',True,'w:gz')]:
    with tarfile.open(root/name,mode,format=tarfile.USTAR_FORMAT) as t:
        if dot:
            e=tarfile.TarInfo('.');e.type=tarfile.DIRTYPE;t.addfile(e)
        content=b'tar data'
        e=tarfile.TarInfo('./a.txt' if dot else 'a.txt');e.size=len(content);t.addfile(e,io.BytesIO(content))
print(root)
