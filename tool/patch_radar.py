"""Ajoute le RADAR au projet Android généré par `flutter create` :
- code Kotlin de android_native/kotlin (MainActivity, service d'écoute des
  notifications, service de premier plan, WebView sans affichage, WorkManager) ;
- icône des notifications ;
- permissions et services dans le manifeste ;
- dépendances androidx (core, work) dans app/build.gradle.kts.
Idempotent."""
import glob
import os
import shutil
import sys

root = sys.argv[1] if len(sys.argv) > 1 else 'android'
src = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'android_native')

# 1. Kotlin
kdir = os.path.join(root, 'app/src/main/kotlin/fr/eddybonnet/mpb_check')
os.makedirs(kdir, exist_ok=True)
for f in glob.glob(os.path.join(src, 'kotlin', '*.kt')):
    shutil.copy(f, kdir)

# 2. ressources
for f in glob.glob(os.path.join(src, 'res', '*', '*')):
    d = os.path.join(root, 'app/src/main/res', os.path.basename(os.path.dirname(f)))
    os.makedirs(d, exist_ok=True)
    shutil.copy(f, d)

# 3. manifeste
mpath = os.path.join(root, 'app/src/main/AndroidManifest.xml')
m = open(mpath, encoding='utf-8').read()
perms = ['FOREGROUND_SERVICE', 'FOREGROUND_SERVICE_DATA_SYNC', 'POST_NOTIFICATIONS',
         'REQUEST_IGNORE_BATTERY_OPTIMIZATIONS']
for p in perms:
    tag = f'<uses-permission android:name="android.permission.{p}"/>'
    if tag not in m:
        m = m.replace('<application', tag + '\n    <application', 1)
services = '''        <!-- RADAR : écoute des notifications Leboncoin -->
        <service
            android:name=".RadarNotificationListener"
            android:label="MPB Check Radar"
            android:exported="true"
            android:permission="android.permission.BIND_NOTIFICATION_LISTENER_SERVICE">
            <intent-filter>
                <action android:name="android.service.notification.NotificationListenerService"/>
            </intent-filter>
        </service>
        <!-- RADAR : traitement court en arrière-plan -->
        <service
            android:name=".RadarService"
            android:exported="false"
            android:foregroundServiceType="dataSync"/>
'''
if 'RadarNotificationListener' not in m:
    i = m.rindex('\n', 0, m.index('</application>')) + 1
    m = m[:i] + services + m[i:]
open(mpath, 'w', encoding='utf-8').write(m)

# 4. dépendances
gpath = os.path.join(root, 'app/build.gradle.kts')
g = open(gpath, encoding='utf-8').read()
if 'androidx.work:work-runtime-ktx' not in g:
    g += '''
dependencies {
    implementation("androidx.core:core-ktx:1.13.1")
    implementation("androidx.work:work-runtime-ktx:2.9.1")
}
'''
open(gpath, 'w', encoding='utf-8').write(g)

for needle in ('RadarNotificationListener', 'BIND_NOTIFICATION_LISTENER_SERVICE', 'FOREGROUND_SERVICE_DATA_SYNC',
               'POST_NOTIFICATIONS', 'REQUEST_IGNORE_BATTERY_OPTIMIZATIONS', 'foregroundServiceType="dataSync"'):
    if needle not in m:
        sys.exit('Manifeste incomplet : ' + needle)
print('Radar ajouté au projet Android')
