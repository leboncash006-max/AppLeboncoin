# MPB Check

Appli Android : tu colles (ou partages) le lien d'une annonce Leboncoin, elle te dit
combien MPB te la reprendrait, quelle marge tu peux faire, et tu peux poser des
questions à l'IA sur l'annonce.

## Nouveautés de la v2
- **Vrai prix de reprise MPB** : l'appli interroge l'API publique de reprise de MPB
  (`/public-api/v1/models/purchase-price/<id>/<état>/`, en-tête `X-Market: fr`) et récupère
  les 5 prix (Comme neuf → Très usé). La marge principale utilise l'état annoncé sur
  Leboncoin, et une **marge prudente** utilise l'état juste en dessous.
- **Partage direct** : dans l'appli Leboncoin, *Partager › MPB Check* lance l'analyse
  tout de suite (réception de `ACTION_SEND text/*` via `receive_sharing_intent`).
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
  une carte par élément (nom MPB, reprise, badge « Prix MPB réel », mini-échelle des
  5 prix avec l'état retenu mis en avant, nombre en vente chez MPB, lien vers la page MPB), alertes en
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
4. **Accès à MPB par WebView** : l'anti-robot de MPB refuse (HTTP 403) le client HTTP de
   l'appli. Les appels MPB partent donc d'une page mpb.com ouverte dans une WebView
   repliée (`lib/services/mpb_web_transport.dart`), comme un vrai navigateur. Si MPB
   demande une vérification, la WebView se déplie pour que tu la fasses.
5. **Identification sans IA (par défaut)** : `lib/services/local_identifier.dart` reconnaît
   boîtiers (marque + référence : 1200D, A68, X-T3, a7 III…), objectifs (focale 18-55,
   départagée par l'ouverture et IS/STM/VR/II…), flashs, défauts (HS, pour pièces,
   champignon, rayure…, en ignorant « aucune rayure »), déclenchements et état, avec le
   catalogue MPB local. **Aucun appel à Gemini** quand quelque chose est reconnu ; Gemini ne
   sert qu'en secours (rien reconnu, catalogue absent). Réglages › « Identification sans IA ».
   Le chat « Poser une question » reste sur Gemini.
5 bis. **Catalogue local des noms exacts** : le moteur de recherche MPB ne trouve un modèle
   qu'avec son nom quasi exact (« Sony A68 » ne trouve pas « Sony Alpha SLT-A68 »).
   L'appli télécharge donc une fois la liste complète des modèles MPB (nom exact +
   identifiant), la garde en local (`lib/services/mpb_catalog.dart`) et la rafraîchit
   chaque semaine (bouton « Retélécharger » dans les réglages). Chaque élément est
   comparé en local, en donnant plus de poids aux références (A68, 1200D, 18-55…) :
   nom exact → retenu directement, sans IA ; sinon les noms les plus proches sont
   proposés à Gemini. L'identifiant vient aussi du catalogue (un appel de moins).
   Le moteur de recherche MPB ne sert plus qu'en secours.
6. **Prix de reprise réel** :
   - identifiant MPB du modèle : `GET /search-service/product/query/` avec
     `filter_query[object_type]=model` et le nom exact (marche aussi hors stock) ;
   - 5 prix : `GET /public-api/v1/models/purchase-price/<id>/<état>/` avec `X-Market: fr`
     (sinon prix en GBP ; la devise `EUR` est vérifiée). Appels en séquence (~300 ms
     d'écart), cache local de 24 h par id + état ;
   - état retenu d'après l'attribut « État » de l'annonce :

     | Leboncoin | MPB |
     |---|---|
     | État neuf | `like-new` |
     | Très bon état | `excellent` |
     | Bon état | `good` |
     | État satisfaisant | `well-used` |
     | Pour pièces | aucun rachat (0 € + alerte ⛔) |
     | inconnu | `good` |

   - marge = reprise pour l'état annoncé − prix ; marge prudente = même calcul avec
     l'état juste en dessous.
   - **Secours** si l'API ne répond pas : ancienne estimation enregistrée
     (`lib/data/real_quotes.dart`), sinon médiane de revente MPB en état Bon × 0,54
     (boîtier) ou × 0,40 (objectif). C'est alors affiché « estimation approximative ».
7. **Résultat**, puis questions éventuelles à l'IA (qui connaît aussi les 5 prix de
   chaque élément).

Saisie manuelle : bouton « Saisir le texte à la main » sous le champ du lien.

## Radar : analyse automatique des recherches enregistrées

L'appli Leboncoin envoie une notification par recherche enregistrée (titre = nom de la
recherche, texte « De nouveaux résultats sont disponibles »). Le radar s'en sert comme
déclencheur : il ouvre la recherche, trouve les nouvelles annonces et les analyse tout seul.

### Mise en route
1. Onglet **Radar** › menu › **Permissions et réglages** : les trois lignes doivent être vertes.
   - **Accès aux notifications** : active « MPB Check Radar ».
   - **Optimisation de la batterie désactivée** : obligatoire, c'est ce qui autorise le
     service de premier plan à démarrer en arrière-plan (Android 12+).
   - **Notifications de MPB Check** (Android 13+).
2. Onglet **Radar** › icône loupe › **Ajouter** : nom = **exactement** le titre de la
   notification Leboncoin (« objectif », « TOUTES CATÉGORIES »… ; casse et accents
   ignorés), URL `leboncoin.fr/recherche?…` (`sort=time` est ajouté si absent), prix max
   (200 € par défaut), catégorie (16 = Photo, audio & vidéo par défaut).
   Une notification reçue sans recherche associée apparaît dans **Notifications reçues**,
   avec un bouton « Créer la recherche ».

### Fonctionnement
- `RadarNotificationListener.kt` reçoit les notifications dont le package contient
  « leboncoin », met l'événement en file et lance `RadarService.kt` (service de premier plan
  court, notification discrète « Radar : … »). La notification de recherche est ensuite
  **retirée** pour pouvoir réapparaître normalement (les messages Leboncoin ne sont pas touchés).
- Le service démarre le code Dart du radar (`radarMain`, `lib/radar/`) dans un moteur Flutter
  sans écran. Un seul traitement à la fois ; plusieurs notifications sont fusionnées ; au
  moins 60 s entre deux chargements d'une même recherche.
- La page de recherche est lue dans une WebView sans affichage (`HeadlessBrowser.kt`, cookies
  partagés avec la WebView visible) : `__NEXT_DATA__ › props.pageProps.searchData.ads`.
- **Nouvelles annonces** : la 1re fois, les **3 plus récentes** ; ensuite, **toutes celles
  parues depuis la dernière vue** (point de reprise enregistré par recherche + table des
  annonces vues). Les annonces boostées, en tête mais souvent anciennes, sont triées par date.
  Gardées si : jamais vue, prix ≤ max, bonne catégorie, publiée il y a moins de 24 h.
- **Analyse en 2 temps** : (a) pré-analyse sur titre + attributs (Gemini + prix MPB réel) ;
  si la marge provisoire < seuil − 15 €, on s'arrête là ; (b) sinon la page de l'annonce est
  ouverte et analysée avec sa description.
- **Résultat** : notification si marge ≥ seuil (« +45 € · Canon EOS 1200D + 18-55 »,
  « 50 € → reprise 95 € (Excellent) · objectif », boutons Annonce / Analyse ; priorité haute
  si marge ≥ 2 × seuil). Fil complet dans l'onglet Radar (rentables en haut), filtre par
  recherche, appui → écran résultat avec le chat IA. Tableau de bord du jour.

### Notification déclencheur
Seule la notification Leboncoin **choisie** lance le radar (et est retirée ensuite) ; les
autres (messages, offres…) sont ignorées. Radar › menu › **Notification à écouter** (ou
depuis le test global) : attends une notification de recherche, reviens dans l'appli et
appuie sur « Écouter celle-ci ». Sans choix, le radar reconnaît le texte habituel
« … nouveaux résultats … ».

### Fonctionnement en arrière-plan
L'appli n'a pas besoin de tourner en permanence : Android garde l'écoute des notifications
branchée et réveille l'appli à chaque notification. Pour que le système ne la coupe pas :
accès aux notifications, optimisation de batterie désactivée, batterie « Non restreinte »
(Samsung : retirer des applis en veille ; Xiaomi : démarrage automatique). L'écouteur se
rebranche tout seul s'il est débranché, et un **chien de garde** (toutes les 15 min) envoie
une notification **« Radar arrêté »** si l'écoute est coupée, l'accès retiré, l'arrière-plan
restreint ou un démarrage refusé.

### Test global, toutes les annonces, PDF
- **Test global** (Radar › Test) : autorisations, écoute des notifications, déclencheur,
  service en arrière-plan, chien de garde, chaque clé Gemini, catalogue MPB, identification
  sans IA, API de reprise MPB, lecture d'une page Leboncoin, état du radar. Rapport copiable.
- **Toutes les annonces** (Radar › Tout voir) : les analysées (marge, recherche texte, filtre
  « rentables », par recherche) et toutes les annonces vues avec ce que le radar en a fait
  (analysée, trop chère, trop ancienne, antérieure au point de reprise…).
- **Export PDF** (Radar › PDF, Tout voir, ou historique de l'onglet Analyse) : toutes les
  annonces du radar, seulement les rentables, ou l'historique ; aujourd'hui / 7 j / 30 j /
  tout. Tableau + détail (modèles MPB, 5 prix de reprise, alertes, liens). Partage Android.

### Limites et sécurité
- 30 pages d'annonces par heure au maximum, 3 s minimum entre deux pages Leboncoin.
- **Vérification Leboncoin** (captcha / DataDome) : le radar s'arrête et envoie une
  notification « Leboncoin demande une vérification ». À l'appui, la page s'ouvre dans une
  WebView **visible** : tu fais la vérification toi-même, puis « C'est fait » relance le radar.
  Aucun contournement, aucune résolution automatique.
- 3 échecs réseau de suite : pause de 30 min.
- **Filet de sécurité** (désactivé par défaut) : WorkManager relance les recherches actives
  toutes les 60 min, avec les mêmes limites.
- Journal : Radar › menu › Journal (ou Réglages › Journal du radar).
- Stockage : sqflite (`radar.db` : recherches, annonces vues, analyses, notifications, journal).

### Fichiers
- `android_native/kotlin/` : code Kotlin copié dans le projet Android par `tool/patch_radar.py`
  (qui ajoute aussi les permissions FOREGROUND_SERVICE(_DATA_SYNC), POST_NOTIFICATIONS,
  REQUEST_IGNORE_BATTERY_OPTIMIZATIONS, le service BIND_NOTIFICATION_LISTENER_SERVICE et les
  dépendances androidx).
- `lib/radar/` : base de données, moteur, navigateur sans affichage, pont Android.
- `lib/screens/radar_*.dart` : écrans du radar.

## Clés et modèles Gemini
Dans `lib/secrets.dart` : modèle `gemini-flash-lite-latest` (repli automatique sur
`gemini-3.5-flash-lite` si l'alias est refusé) et clés API en dur (même compte). La première
clé est utilisée ; on passe à la suivante si elle est invalide ou à court de quota (429,
après une relance de 4 s). La clé qui marche est gardée pour la suite ; si toutes sont à
court de quota, un message clair s'affiche.

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

> **Signature** : l'APK est signé avec la clé fixe de `signing/` (`mpb-check.jks`,
> mots de passe dans `key.properties`), branchée par `tool/patch_signing.py`. Chaque
> nouvelle version s'installe donc par-dessus la précédente, sans désinstaller (le numéro
> de build Android augmente à chaque run). Le workflow vérifie l'empreinte du certificat
> (SHA-256 `59:10:76:AC:…:81:73:47`). **Garde une copie de ce dossier** : sans cette clé,
> plus aucune mise à jour ne pourra s'installer par-dessus. Et garde le dépôt privé.

### Option B : sur ton PC avec Flutter
```bash
flutter create --org fr.eddybonnet --project-name mpb_check --platforms android .
python3 tool/patch_manifest.py
python3 tool/patch_signing.py
python3 tool/patch_radar.py android
flutter pub get
dart run flutter_launcher_icons
flutter build apk --release
```
L'APK est dans `build/app/outputs/flutter-apk/`.

## Fichiers
- `lib/services/leboncoin_reader.dart` : lecture de la page (testé sur la structure réelle le 09/10/2026)
- `lib/services/mpb_web_transport.dart` : requêtes MPB depuis une WebView mpb.com
- `lib/services/local_identifier.dart` : identification sans IA
- `lib/screens/export_pdf.dart`, `assets/fonts/` : export PDF (police Roboto, Apache 2.0)
- `lib/services/mpb_catalog.dart` : catalogue local des noms exacts MPB
- `lib/services/mpb_service.dart` : API JSON de MPB (suggestions, annonces en vente, identifiant et prix de reprise réels)
- `lib/services/gemini_service.dart` : appels Gemini (JSON imposé pour l'analyse, chat avec recherche)
- `lib/services/analyzer.dart` : enchaînement complet de l'analyse
- `lib/services/history.dart` : historique local (50 analyses + conversations)
- `lib/screens/` : accueil, analyse, résultat, questions, réglages
- `lib/theme.dart`, `lib/widgets/common.dart` : thème et composants
- `assets/icon/` : icône de l'appli
- `tool/patch_manifest.py` : ajouts au manifeste Android
- `tool/patch_signing.py`, `signing/` : signature fixe de l'APK
