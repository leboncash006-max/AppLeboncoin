"""Fait signer l'APK de release avec la clé fixe du dépôt (signing/), pour que
chaque nouvelle version s'installe par-dessus la précédente sans désinstaller.
À lancer après `flutter create`. Idempotent."""
import os
import sys

gradle = sys.argv[1] if len(sys.argv) > 1 else 'android/app/build.gradle.kts'
props_path = 'signing/key.properties'

props = {}
for line in open(props_path, encoding='utf-8'):
    if '=' in line and not line.lstrip().startswith('#'):
        k, v = line.strip().split('=', 1)
        props[k] = v
store = os.path.abspath(os.path.join(os.path.dirname(props_path), props['storeFile']))
if not os.path.isfile(store):
    sys.exit(f'Keystore introuvable : {store}')

g = open(gradle, encoding='utf-8').read()
if 'create("release")' not in g:
    block = f'''    signingConfigs {{
        create("release") {{
            storeFile = file("{store}")
            storePassword = "{props['storePassword']}"
            keyAlias = "{props['keyAlias']}"
            keyPassword = "{props['keyPassword']}"
        }}
    }}

'''
    i = g.index('    buildTypes {')
    g = g[:i] + block + g[i:]
old = 'signingConfig = signingConfigs.getByName("debug")'
if old in g:
    g = g.replace(old, 'signingConfig = signingConfigs.getByName("release")', 1)
if 'signingConfigs.getByName("release")' not in g:
    sys.exit('Impossible de brancher la signature release dans ' + gradle)
open(gradle, 'w', encoding='utf-8').write(g)
print('Signature release : ' + store)
