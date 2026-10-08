import urllib.request
from pathlib import Path
base='https://www.unicode.org/Public/17.0.0/ucd/'
ranges={'zero':[],'wide':[]}
for file, name, categories in [('extracted/DerivedGeneralCategory.txt','zero',{'Mn','Me','Mc','Cf'}),('EastAsianWidth.txt','wide',{'W','F'})]:
 text=urllib.request.urlopen(base+file,timeout=30).read().decode()
 for line in text.splitlines():
  line=line.split('#')[0].strip()
  if not line:continue
  field,category=map(str.strip,line.split(';'))
  if category not in categories:continue
  pair=field.split('..');a=int(pair[0],16);b=int(pair[-1],16)
  ranges[name].append((a,b))
text=urllib.request.urlopen(base+'emoji/emoji-variation-sequences.txt',timeout=30).read().decode()
ranges['emojiVariation']=[(int(line.split(';')[0].split()[0],16),)*2 for line in text.splitlines() if '; emoji style;' in line]
for name, pairs in ranges.items():
 merged=[]
 for a,b in sorted(pairs):
  if merged and a<=merged[-1][1]+1:merged[-1]=(merged[-1][0],max(b,merged[-1][1]))
  else:merged.append((a,b))
 ranges[name]=merged
out=['// Unicode 17.0 UCD: Mn/Me/Mc/Cf and East_Asian_Width W/F ranges.', '// Generated from unicode.org data; see docs/ssh-stage-4.ru.md.', '// Unicode data license: https://www.unicode.org/license.txt', "part of 'terminal_screen.dart';"]
for name,pairs in ranges.items():
 out.append('const _'+name+'Ranges = <int>[')
 for a,b in pairs:out.append(f'  0x{a:x}, 0x{b:x},')
 out.append('];')
Path('lib/core/terminal/terminal_unicode.dart').write_text('\n'.join(out)+'\n')

Path('docs/unicode-license.txt').write_bytes(urllib.request.urlopen('https://www.unicode.org/license.txt',timeout=30).read())
