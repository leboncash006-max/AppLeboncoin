# MPB Check

Appli Android : tu colles (ou partages) le lien d'une annonce Leboncoin, elle te dit
combien MPB te la reprendrait, quelle marge tu peux faire, et tu peux poser des
questions à l'IA sur l'annonce.

## Nouveautés de la v2
- **Partage direct** : dans l'appli Leboncoin, *Partager › MPB Check* lance l'analyse
  tout de suite (réception de `ACTION_SEND text/plain` via `receive_sharing_intent`).
- **Presse-papiers** : au lancement et au retour dans l'appli, si un lien Leboncoin a été
  copié, une bannière propose « Analyser l'annonce copiée ? ». Le lien est extrait du texte
  partagé par une simple regex (`extractLeboncoinUrl`), sans IA.
- **Nouvelle interface** Material 3 : thème sombre par défaut (clair dans les réglages),
  accent violet, polices Inter et Manrope (`google_fonts`), cartes arrondies.
- **Analyse en étapes animées** : Lecture de l'annonce → Identification → Catalogue MPB →
  Calcul. La page Leboncoin est repliée, et se déplie toute seule si Leboncoin demande
  une vérification.
- **Écran résultat** : marge en très gros (vert / orange / rouge) avec verdict,
  prix annonce → reprise MPB, carte annonce (état, marque, description repliable),
  une carte par élément (nom MPB, reprise, source « estimation réelle » ou
  « revente × coef », nombre en vente chez MPB, lien vers la page MPB), alertes en
  bandeaux (⛔ « pour pièces » en rouge, en haut).
- **Historique** : les 50 dernières analyses, en local. Un appui rouvre le résultat sans
  nouvel appel ; glisser vers la gauche pour supprimer (avec « Annuler »).
- **Poser une question** : chat avec Gemini qui connaît l'annonce et toute l'analyse,
  avec recherche Google (sources cliquables sous la réponse) et rendu Markdown.
  La conversation est enregistrée avec l'analyse.
- **Icône** de l'appli (`assets/icon/`), générée pour Android pendant le build.

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
5. **Résultat**, puis questions éventuelles à l'IA.

Saisie manuelle : bouton « Saisir le texte à la main » sous le champ du lien.

## Clés et modèles Gemini
Dans `lib/secrets.dart` : modèle `gemini-flash-lite-latest` (repli automatique sur
`gemini-3.5-flash-lite` si l'alias est refusé) et clés API en dur. La première clé est
utilisée ; les suivantes ne servent que si elle est invalide ou révoquée (pas de rotation
pour contourner les quotas).

Pour le chat (`GeminiService.chat`) : texte libre, sans `responseSchema`, avec l'outil
`google_search`. Si le modèle refuse l'outil, l'appel est refait avec
`gemini-flash-latest`, puis sans outil en dernier recours. Un quota dépassé (429) affiche
un message clair.

**Garde le dépôt privé.** En offre gratuite, Google peut utiliser les textes envoyés.

## Obtenir l'APK

### Option A : GitHub, sans rien installer
1. Onglet **Actions** → « Build APK » → **Run workflow** (ou pousse sur `main`).
2. Après 5 à 8 minutes, télécharge l'artefact **mpb-check-apk** (un zip qui contient `app-release.apk`).
3. Installe-le sur ton téléphone (autorise « sources inconnues »).

Le workflow génère `android/` avec `flutter create`, complète le manifeste avec
`tool/patch_manifest.py` (permission INTERNET, nom « MPB Check », partage Android,
`singleTask`), génère l'icône (`flutter_launcher_icons`), puis lance `flutter analyze` et
`flutter build apk --release`.

> L'APK est signé avec une clé de débogage créée à chaque build. Si Android refuse la mise à
> jour (« conflit avec un paquet existant »), désinstalle l'ancienne version d'abord
> (l'historique et les réglages sont alors effacés).

### Option B : sur ton PC avec Flutter
```bash
flutter create --org fr.eddybonnet --project-name mpb_check --platforms android .
python3 tool/patch_manifest.py
flutter pub get
dart run flutter_launcher_icons
flutter build apk --release
```
L'APK est dans `build/app/outputs/flutter-apk/`.

## Fichiers
- `lib/services/leboncoin_reader.dart` : lecture de la page (testé sur la structure réelle le 09/10/2026)
- `lib/services/mpb_service.dart` : API JSON de MPB (suggestions + annonces en vente)
- `lib/services/gemini_service.dart` : appels Gemini (JSON imposé pour l'analyse, chat avec recherche)
- `lib/services/analyzer.dart` : enchaînement complet de l'analyse
- `lib/services/history.dart` : historique local (50 analyses + conversations)
- `lib/screens/` : accueil, analyse, résultat, questions, réglages
- `lib/theme.dart`, `lib/widgets/common.dart` : thème et composants
- `assets/icon/` : icône de l'appli
- `tool/patch_manifest.py` : ajouts au manifeste Android
