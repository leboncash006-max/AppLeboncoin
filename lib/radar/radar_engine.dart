import 'dart:convert';

import 'package:flutter/services.dart';

import '../messages/auto_sender.dart';
import '../messages/message_store.dart';
import '../models.dart';
import '../services/analyzer.dart';
import '../services/history.dart';
import '../services/mpb_catalog.dart';
import '../services/mpb_service.dart';
import '../services/settings.dart';
import 'native_browser.dart';
import 'radar_db.dart';

/// Normalise un titre pour comparer notification et recherche
/// (sans casse, sans accents, espaces simplifiés).
String normTitle(String s) {
  var t = s.toLowerCase().trim();
  const accents = {
    'é': 'e', 'è': 'e', 'ê': 'e', 'ë': 'e', 'à': 'a', 'â': 'a', 'ä': 'a', 'î': 'i', 'ï': 'i',
    'ô': 'o', 'ö': 'o', 'û': 'u', 'ù': 'u', 'ü': 'u', 'ç': 'c',
  };
  accents.forEach((a, b) => t = t.replaceAll(a, b));
  return t.replaceAll(RegExp(r'\s+'), ' ');
}

/// Limites (voir README) : jamais de contournement d'une vérification.
class RadarLimits {
  static const firstRunAds = 3; // 1re notification : les 3 plus récentes
  static const minGapSameSearch = Duration(seconds: 60);
  static const minGapLbcPages = Duration(seconds: 3);
  static const maxAdPagesPerHour = 30;
  static const maxAge = Duration(hours: 24);
  static const failuresBeforePause = 3;
  static const pause = Duration(minutes: 30);
  static const preMarginSlack = 15.0; // pré-analyse : stop si marge < seuil − 15 €
}

/// Moteur du radar, exécuté dans le service de premier plan (moteur Flutter
/// sans écran). Traite les événements un par un jusqu'à ce qu'il n'y en ait plus.
class RadarEngine {
  static const bg = MethodChannel('mpb_check/radar_bg');

  RadarEngine({this.analyzerFactory});

  /// Pour les tests : fabrique d'Analyzer (sinon Gemini + MPB via WebView).
  final Future<Analyzer> Function(Settings settings)? analyzerFactory;

  final _lbc = NativeBrowser('lbc');
  NativeMpbFetch? _mpbFetch;
  MpbService? _mpb;
  MpbCatalog? _catalog;
  Settings? _settings;
  bool _running = false;
  bool _wakeAgain = false;

  void wake() {
    if (_running) {
      _wakeAgain = true;
    } else {
      run();
    }
  }

  Future<void> run() async {
    _running = true;
    await _live(step: 'Démarrage du radar', clearAd: true);
    try {
      do {
        _wakeAgain = false;
        await _processEvents();
        await _sendQueue();
      } while (_wakeAgain);
    } catch (e) {
      await RadarDb.log('Erreur radar : $e');
    } finally {
      _running = false;
      await _liveDone();
      await _progress('Radar : terminé');
      await bg.invokeMethod('done');
    }
  }

  /// Messages en file : envoyés quand les garde-fous le permettent. Si le
  /// prochain est dû dans moins de 6 min, on l'attend (service toujours actif).
  Future<void> _sendQueue() async {
    try {
      for (var round = 0; round < 5; round++) {
        await AutoSender.processQueue(onLive: (t) => _live(step: t, clearAd: true));
        final next = await MessageStore.nextQueued();
        if (next == null) return;
        final wait = next.difference(DateTime.now());
        if (wait > const Duration(minutes: 6)) return;
        if (!wait.isNegative) {
          await _live(step: 'Prochain message dans ${wait.inSeconds} s (garde-fous)', clearAd: true);
          await Future.delayed(wait);
        }
      }
    } catch (e) {
      await RadarDb.log('✉️ File des messages : $e');
    }
  }

  // ------------------------------------------------------------ en direct

  final Map<String, Object?> _liveState = {};

  /// Ce que fait le radar à l'instant (lu par l'onglet Radar, chaque seconde).
  Future<void> _live({
    String? search,
    String? step,
    String? detail,
    SearchAd? ad,
    int? index,
    int? total,
    bool clearAd = false,
  }) async {
    if (search != null) _liveState['search'] = search;
    if (step != null) _liveState['step'] = step;
    _liveState['detail'] = detail;
    if (clearAd) {
      _liveState
        ..remove('ad')
        ..remove('index')
        ..remove('total');
    }
    if (ad != null) {
      _liveState['ad'] = {'title': ad.subject, 'price': ad.price, 'url': ad.url};
    }
    if (index != null) _liveState['index'] = index;
    if (total != null) _liveState['total'] = total;
    _liveState['running'] = true;
    _liveState['ts'] = DateTime.now().millisecondsSinceEpoch;
    try {
      await RadarDb.set('live', jsonEncode(_liveState));
    } catch (_) {}
  }

  Future<void> _liveDone() async {
    try {
      await RadarDb.set('live', jsonEncode({'running': false, 'ts': DateTime.now().millisecondsSinceEpoch}));
    } catch (_) {}
  }

  Future<void> _progress(String text) async {
    try {
      await bg.invokeMethod('progress', {'text': text});
    } catch (_) {}
  }

  // ---------------------------------------------------------------- événements

  Future<void> _processEvents() async {
    final raw = await bg.invokeMethod<String>('takeEvents') ?? '[]';
    final events = (jsonDecode(raw) as List).map((e) => Map<String, dynamic>.from(e as Map)).toList();
    if (events.isEmpty) return;
    final searches = await RadarDb.searches();
    final toRun = <int>{}; // ids des recherches à charger (notifications fusionnées)

    for (final ev in events) {
      final kind = ev['kind'] as String? ?? '';
      final at = DateTime.fromMillisecondsSinceEpoch((ev['ts'] as num?)?.toInt() ?? 0);
      if (kind == 'notif') {
        final title = (ev['title'] ?? '').toString();
        final text = (ev['text'] ?? '').toString();
        final pkg = (ev['pkg'] ?? '').toString();
        if (await RadarDb.get('first_pkg') == null) {
          await RadarDb.set('first_pkg', pkg);
          await RadarDb.log('Première notification Leboncoin : package « $pkg »');
        }
        final match = searches.where((s) => normTitle(s.name) == normTitle(title)).toList();
        // (titre « objectif », « TOUTES CATÉGORIES »… = nom de la recherche enregistrée)
        await RadarDb.addNotif(title, text, pkg, match.isEmpty ? null : match.first.id, at);
        if (match.isEmpty) {
          // c'est bien la notification déclencheur (filtrée côté Android), mais son
          // titre ne correspond à aucun nom : on lance toutes les recherches actives
          final actives = searches.where((x) => x.active).toList();
          // titre ou texte qui CONTIENT le nom d'une recherche
          final loose = actives
              .where((x) => normTitle('$title $text').contains(normTitle(x.name)))
              .toList();
          final run = loose.isNotEmpty ? loose : actives;
          toRun.addAll(run.map((x) => x.id!));
          await RadarDb.log('Notif « $title » : pas de recherche de ce nom exact → '
              '${run.map((x) => '« ${x.name} »').join(', ')}');
          continue;
        }
        for (final s in match) {
          if (s.active) {
            toRun.add(s.id!);
            await RadarDb.log('Notif « $title » → recherche « ${s.name} »');
          } else {
            await RadarDb.log('Notif « $title » : recherche désactivée');
          }
        }
      } else if (kind == 'test') {
        // test global : prouve que le service en arrière-plan démarre, sans rien charger
        await RadarDb.log('Test global : service en arrière-plan OK');
      } else {
        // relance manuelle, périodique ou après vérification : toutes les actives
        toRun.addAll(searches.where((s) => s.active).map((s) => s.id!));
        await RadarDb.log('Relance « $kind » : ${toRun.length} recherche(s)');
      }
    }
    if (toRun.isEmpty) return;

    final state = await RadarDb.state();
    if (state == RadarState.verify) {
      await RadarDb.log('Radar en attente de vérification Leboncoin : rien n\'est chargé');
      return;
    }
    if (state == RadarState.paused) {
      await RadarDb.log('Radar en pause (erreurs réseau) : rien n\'est chargé');
      return;
    }

    _settings = await Settings.load();
    for (final s in searches.where((s) => toRun.contains(s.id))) {
      final ok = await _runSearch(s);
      if (!ok) break; // vérification demandée ou pause
    }
  }

  // ------------------------------------------------------------------ recherche

  Future<void> _waitLbcGap() async {
    final last = await RadarDb.lastPageLoad();
    if (last == null) return;
    final wait = RadarLimits.minGapLbcPages - DateTime.now().difference(last);
    if (!wait.isNegative) await Future.delayed(wait);
  }

  /// false si le radar doit s'arrêter (vérification, pause).
  Future<bool> _runSearch(RadarSearch s) async {
    // au moins 60 s entre deux chargements de la même recherche
    if (s.lastLoadedAt != null) {
      final wait = RadarLimits.minGapSameSearch - DateTime.now().difference(s.lastLoadedAt!);
      if (!wait.isNegative) {
        await RadarDb.log('« ${s.name} » chargée il y a moins de 60 s : attente ${wait.inSeconds} s');
        await _live(search: s.name, step: 'Pause de ${wait.inSeconds} s (60 s entre deux chargements)', clearAd: true);
        await Future.delayed(wait);
      }
    }
    await _progress('Radar : recherche « ${s.name} »…');
    await _live(search: s.name, step: 'Chargement de la recherche Leboncoin', clearAd: true);
    await _waitLbcGap();
    await RadarDb.addPageLoad('search');
    final page = await loadSearchPage(_lbc, s.url);

    if (page.blocked) {
      await _askVerification(s.url);
      return false;
    }
    if (!page.ok) {
      final fails = await RadarDb.getInt('failures') + 1;
      await RadarDb.setInt('failures', fails);
      await RadarDb.log('« ${s.name} » : échec du chargement (${page.error}), $fails de suite');
      if (fails >= RadarLimits.failuresBeforePause) {
        await RadarDb.setInt(
            'paused_until', DateTime.now().add(RadarLimits.pause).millisecondsSinceEpoch);
        await RadarDb.setInt('failures', 0);
        await RadarDb.log('3 échecs de suite : radar en pause 30 min');
        return false;
      }
      return true;
    }
    await RadarDb.setInt('failures', 0);

    // ---- sélection des nouvelles annonces (point de reprise)
    final ads = page.ads;
    final seen = await RadarDb.seenAmong(ads.map((a) => a.listId).toList());
    final byDate = [...ads]..sort((a, b) => (b.date ?? DateTime(2000)).compareTo(a.date ?? DateTime(2000)));
    final unseen = byDate.where((a) => !seen.contains(a.listId)).toList();
    final List<SearchAd> fresh;
    if (s.checkpoint == null) {
      // première fois : les 3 annonces les plus récentes
      fresh = unseen.take(RadarLimits.firstRunAds).toList();
    } else {
      // toutes celles parues depuis la dernière annonce vue
      fresh = unseen.where((a) => a.date != null && !a.date!.isBefore(s.checkpoint!)).toList();
    }
    final newest = byDate.where((a) => a.date != null && !a.boosted).map((a) => a.date!).fold<DateTime?>(
        s.checkpoint, (m, d) => m == null || d.isAfter(m) ? d : m);
    // annonces antérieures au point de reprise : vues, pas analysées
    final freshIds = fresh.map((a) => a.listId).toSet();
    for (final a in unseen.where((a) => !freshIds.contains(a.listId))) {
      await RadarDb.markSeenAd(s.id!, a.listId,
          title: a.subject, price: a.price, url: a.url, publishedAt: a.date,
          reason: s.checkpoint == null ? 'déjà en ligne au 1er passage' : 'antérieure au point de reprise');
    }
    await RadarDb.setCheckpoint(s.id!, newest);

    final now = DateTime.now();
    final candidates = <SearchAd>[];
    for (final a in fresh) {
      String? why;
      if (a.date == null || now.difference(a.date!) > RadarLimits.maxAge) {
        why = 'publiée il y a plus de 24 h';
      } else if (a.price == null || a.price! > s.maxPrice) {
        why = 'prix ${a.price?.toStringAsFixed(0) ?? '?'} € > ${s.maxPrice.toStringAsFixed(0)} €';
      } else if (s.category.isNotEmpty && a.categoryId != s.category) {
        why = 'catégorie ${a.categoryId}';
      }
      await RadarDb.markSeenAd(s.id!, a.listId,
          title: a.subject, price: a.price, url: a.url, publishedAt: a.date, reason: why ?? 'analysée');
      if (why == null) {
        candidates.add(a);
      } else {
        await RadarDb.log('  ignorée : « ${a.subject} » ($why)');
      }
    }
    await RadarDb.log('« ${s.name} » : ${ads.length} annonces, ${fresh.length} nouvelles, '
        '${candidates.length} à analyser');

    await _live(
        step: '${ads.length} annonces lues, ${fresh.length} nouvelle(s), ${candidates.length} à analyser');
    for (var i = 0; i < candidates.length; i++) {
      final a = candidates[i];
      // 4 min au plus par annonce : le radar ne reste jamais bloqué sur une page
      final go = await _analyze(s, a, i + 1, candidates.length).timeout(const Duration(minutes: 4), onTimeout: () async {
        await RadarDb.log('  « ${a.subject} » : trop long (4 min), annonce suivante');
        await _lbc.dispose(); // WebView neuve pour la suite
        return true;
      });
      if (!go) return false;
    }
    return true;
  }

  Future<void> _askVerification(String url) async {
    await _live(step: '⛔ Leboncoin demande une vérification : radar arrêté');
    await RadarDb.set('state', 'verify');
    await RadarDb.set('verify_url', url);
    await RadarDb.log('⛔ Leboncoin demande une vérification : radar arrêté');
    try {
      await bg.invokeMethod('notifyVerify', {'url': url});
    } catch (_) {}
  }

  // ------------------------------------------------------------------ analyse

  Future<Analyzer> _analyzer() async {
    if (analyzerFactory != null) return analyzerFactory!(_settings!);
    _mpbFetch ??= NativeMpbFetch();
    _mpb ??= _mpbFetch!.service();
    _catalog ??= await MpbCatalog.ensure(_mpb!);
    return Analyzer(_settings!, mpb: _mpb, catalog: _catalog);
  }

  /// Analyse en 2 temps. false si le radar doit s'arrêter.
  Future<bool> _analyze(RadarSearch s, SearchAd a, [int index = 1, int total = 1]) async {
    final settings = _settings!;
    await _progress('Radar : analyse de « ${a.subject} »…');
    await _live(step: 'Préparation (catalogue MPB)', ad: a, index: index, total: total);
    final analyzer = await _analyzer();

    // a) pré-analyse sans ouvrir l'annonce : titre + attributs
    Analysis pre;
    await _live(step: 'Pré-analyse (titre + état, sans ouvrir l\'annonce)');
    try {
      pre = await analyzer.analyze(a.subject, '', a.price,
          attributes: a.attributesText, onStep: (st) => _live(detail: st), verify: false);
    } catch (e) {
      await RadarDb.log('  « ${a.subject} » : pré-analyse impossible ($e)');
      return true;
    }
    final preMargin = pre.margin;
    if (preMargin != null && preMargin < settings.minMargin - RadarLimits.preMarginSlack) {
      await _store(s, a, pre, 'pre', a.attributes, '');
      await RadarDb.log('  « ${a.subject} » : non rentable (${preMargin.toStringAsFixed(0)} €), page non ouverte');
      await _live(step: 'Non rentable : ${preMargin.toStringAsFixed(0)} € (page non ouverte)');
      return true;
    }

    // b) analyse complète avec la description (limites de débit)
    if (await RadarDb.pageLoadsLastHour('ad') >= RadarLimits.maxAdPagesPerHour) {
      await _store(s, a, pre, 'limit', a.attributes, '');
      await RadarDb.log('  « ${a.subject} » : limite de 30 pages/h atteinte, marge provisoire');
      await _maybeNotify(s, a, pre, provisional: true);
      return true;
    }
    await _live(step: 'Ouverture de l\'annonce (marge provisoire ${preMargin?.toStringAsFixed(0) ?? '?'} €)');
    await _waitLbcGap();
    await RadarDb.addPageLoad('ad');
    final page = await loadAdPage(_lbc, a.url);
    if (page.blocked) {
      await _store(s, a, pre, 'pre', a.attributes, '');
      await _askVerification(a.url);
      return false;
    }
    if (page.ad == null) {
      await _store(s, a, pre, 'pre', a.attributes, '');
      await RadarDb.log('  « ${a.subject} » : ${page.error}, marge provisoire');
      await _maybeNotify(s, a, pre, provisional: true);
      return true;
    }
    final ad = page.ad!;
    Analysis full;
    try {
      await _live(step: 'Analyse complète (description, défauts, prix MPB réels)');
      full = await analyzer.analyze(ad.title, ad.description, ad.price ?? a.price,
          attributes: ad.attributesText, onStep: (st) => _live(detail: st));
    } catch (e) {
      await _store(s, a, pre, 'pre', a.attributes, '');
      await RadarDb.log('  « ${a.subject} » : analyse complète impossible ($e)');
      return true;
    }
    final stored = await _store(s, a, full, 'full', ad.attributes, ad.description, title: ad.title);
    await RadarDb.log('  « ${a.subject} » : marge ${full.margin?.toStringAsFixed(0) ?? '?'} €');
    final fm = full.margin;
    await _live(
        step: fm == null
            ? 'Résultat : marge non estimée'
            : 'Résultat : ${fm >= 0 ? '+' : ''}${fm.toStringAsFixed(0)} €'
                '${fm >= settings.minMargin ? ' · bonne affaire 🔔' : ''}');
    await _maybeNotify(s, a, full);
    // message au vendeur : envoi auto (toutes conditions) ou notification « À confirmer »
    if (fm != null && fm >= settings.minMargin) {
      try {
        await _live(step: 'Message au vendeur : vérification des conditions');
        await AutoSender.consider(stored, a.listId, a.url, settings.minMargin);
      } catch (e) {
        await RadarDb.log('✉️ Préparation du message impossible : $e');
      }
    }
    return true;
  }

  Future<HistoryEntry> _store(RadarSearch s, SearchAd a, Analysis an, String stage, Map<String, String> attrs,
      String description, {String? title}) async {
    final entry = HistoryEntry(
      id: 'radar_${a.listId}',
      date: DateTime.now(),
      url: a.url,
      title: title ?? a.subject,
      adPrice: a.price,
      description: description,
      attributes: attrs,
      analysis: an,
    );
    final m = an.margin;
    await RadarDb.saveAnalysis(
      listId: a.listId,
      search: s,
      title: title ?? a.subject,
      price: a.price,
      url: a.url,
      publishedAt: a.date,
      stage: stage,
      margin: m,
      profitable: m != null && m >= _settings!.minMargin,
      entry: entry,
    );
    return entry;
  }

  Future<void> _maybeNotify(RadarSearch s, SearchAd a, Analysis an, {bool provisional = false}) async {
    final m = an.margin;
    final seuil = _settings!.minMargin;
    if (m == null || m < seuil) return;
    final names = an.items
        .where((i) => i.buyback != null)
        .map((i) => i.mpbModel ?? i.item.nameGuess)
        .join(' + ');
    final sign = m >= 0 ? '+' : '';
    final doubt = an.warnings.contains(suspiciousWarning);
    var title = '${doubt ? '⚠️ À vérifier · ' : ''}$sign${m.toStringAsFixed(0)} € · ${names.isEmpty ? a.subject : names}';
    if (title.length > 80) title = '${title.substring(0, 79)}…';
    final cond = mpbConditionLabels[an.condition] ?? 'Bon';
    final text = '${an.price?.toStringAsFixed(0) ?? '?'} € → reprise ${an.totalBuyback.toStringAsFixed(0)} € '
        '($cond) · ${s.name}${provisional ? ' · provisoire' : ''}';
    try {
      await bg.invokeMethod('notifyDeal', {
        'id': a.listId.hashCode & 0x7fffffff,
        'title': title,
        'text': text,
        'adUrl': a.url,
        'analysisId': a.listId,
        'high': m >= 2 * seuil,
      });
      await RadarDb.log('  🔔 notification : $title');
    } catch (e) {
      await RadarDb.log('  notification impossible : $e');
    }
  }
}
