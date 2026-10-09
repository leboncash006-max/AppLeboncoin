# MPB Check

Appli Android : tu colles le lien d'une annonce Leboncoin, elle te dit combien MPB
te la reprendrait et quelle marge tu peux faire.

## Comment ça marche
1. **Lecture de l'annonce** : la page s'ouvre dans un navigateur intégré (WebView), comme si
   tu la consultais. Le titre, la description, le prix et l'état sont lus dans les données
   de la page. Si Leboncoin affiche une vérification, elle apparaît à l'écran et c'est toi
   qui la fais.
2. **Gemini Flash-Lite** comprend l'annonce : boîtier(s), objectif(s), flash, version
   exacte (IS, STM, VR…), défauts, nombre de déclenchements.
3. **Catalogue MPB** : l'appli cherche les noms exacts chez MPB, puis Gemini choisit le bon.
4. **Prix** : vraie estimation MPB si on l'a (`lib/data/real_quotes.dart`), sinon
   médiane des prix de revente MPB en état Bon × 0,54 (boîtier) ou × 0,40 (objectif).
5. **Résultat** : marge en vert / orange / rouge, détail par élément, alertes
   (pour pièces, version incertaine…), boutons vers l'annonce et vers l'estimation MPB.

Mode « Texte » : tu peux aussi coller le titre et la description à la main.

## Clés et modèle Gemini
Dans `lib/secrets.dart` : modèle `gemini-flash-lite-latest` (repli automatique sur
`gemini-3.5-flash-lite` si l'alias est refusé) et clés API en dur. La première clé est
utilisée ; les suivantes ne servent que si elle est invalide ou révoquée.
**Garde le dépôt privé.** En offre gratuite, Google peut utiliser les textes envoyés.

## Obtenir l'APK

### Option A : GitHub, sans rien installer
1. Crée un dépôt **privé** sur GitHub et envoie-y ce dossier.
2. Onglet **Actions** → « Build APK » → **Run workflow**.
3. Après 5 à 8 minutes, télécharge l'artefact **mpb-check-apk** (un zip qui contient `app-release.apk`).
4. Installe-le sur ton téléphone (autorise « sources inconnues »).

### Option B : sur ton PC avec Flutter
```bash
flutter create --org fr.eddybonnet --project-name mpb_check --platforms android .
flutter pub get
flutter build apk --release
```
Puis ajoute cette ligne dans `android/app/src/main/AndroidManifest.xml`, juste avant `<application` :
```xml
<uses-permission android:name="android.permission.INTERNET"/>
```
(sans elle, l'APK de release n'a pas accès à Internet). L'APK est dans `build/app/outputs/flutter-apk/`.

## Fichiers
- `lib/services/leboncoin_reader.dart` : lecture de la page (testé sur la structure réelle le 09/10/2026)
- `lib/services/mpb_service.dart` : API JSON de MPB (suggestions + annonces en vente)
- `lib/services/gemini_service.dart` : appel Gemini avec réponse JSON imposée
- `lib/services/analyzer.dart` : enchaînement complet
- `lib/screens/` : écran principal et réglages
