"""Complète android/app/src/main/AndroidManifest.xml généré par `flutter create` :
- permission INTERNET ;
- nom affiché « MPB Check » ;
- launchMode singleTask (un seul écran quand on partage plusieurs fois) ;
- réception du partage Android (ACTION_SEND text/plain).
Le script est idempotent : on peut le relancer sans dupliquer les ajouts."""
import re
import sys

path = sys.argv[1] if len(sys.argv) > 1 else 'android/app/src/main/AndroidManifest.xml'
m = open(path, encoding='utf-8').read()

if 'android.permission.INTERNET' not in m:
    m = m.replace('<application', '<uses-permission android:name="android.permission.INTERNET"/>\n    <application', 1)

m = re.sub(r'android:label="[^"]*"', 'android:label="MPB Check"', m, count=1)

if 'android:launchMode=' in m:
    m = re.sub(r'android:launchMode="[^"]*"', 'android:launchMode="singleTask"', m, count=1)
else:
    m = m.replace('android:name=".MainActivity"', 'android:name=".MainActivity"\n            android:launchMode="singleTask"', 1)

if 'android.intent.action.SEND' not in m:
    share = '''            <!-- Partager > MPB Check (lien d'annonce Leboncoin) -->
            <intent-filter>
                <action android:name="android.intent.action.SEND"/>
                <category android:name="android.intent.category.DEFAULT"/>
                <data android:mimeType="text/*"/>
            </intent-filter>
'''
    i = m.rindex('\n', 0, m.index('</activity>')) + 1  # début de la ligne </activity>
    m = m[:i] + share + m[i:]

open(path, 'w', encoding='utf-8').write(m)

for needle in ('android.permission.INTERNET', 'android:label="MPB Check"',
               'android.intent.action.SEND', 'singleTask'):
    if needle not in m:
        sys.exit(f'Manifeste incomplet : {needle} manquant')
print(m)
