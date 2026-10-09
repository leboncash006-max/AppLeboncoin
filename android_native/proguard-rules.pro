# Règles R8 (réduction du code en version release) pour MPB Check.

# WorkManager / Room : la base interne est créée par réflexion
# (sinon : NoSuchMethodException WorkDatabase_Impl.<init> au démarrage)
-keep class * extends androidx.room.RoomDatabase { <init>(...); }
-keep class androidx.work.impl.WorkDatabase_Impl { *; }
-keep class androidx.work.** { *; }
-keep class * extends androidx.work.ListenableWorker {
    public <init>(android.content.Context, androidx.work.WorkerParameters);
}
-keep class androidx.startup.** { *; }

# Radar : tâches WorkManager, services et pont JavaScript de la WebView sans affichage
-keep class fr.eddybonnet.mpb_check.** { *; }
-keepattributes JavascriptInterface
-keepclassmembers class * {
    @android.webkit.JavascriptInterface <methods>;
}
