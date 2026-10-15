import 'package:flutter_test/flutter_test.dart';
import 'package:mpb_check/buy/buy_rules.dart';
import 'package:mpb_check/buy/buy_settings.dart';
import 'package:mpb_check/models.dart';
import 'package:mpb_check/services/deals.dart';
import 'package:mpb_check/services/history.dart';
import 'package:mpb_check/services/net_margin.dart';
import 'package:mpb_check/services/offer.dart';
import 'package:mpb_check/services/settings.dart';
import 'package:mpb_check/services/v3_models.dart';

ItemResult item(String model, double buyback) =>
    ItemResult(ExtractedItem(type: 'boitier', brand: 'Sony', nameGuess: model, searchQuery: model), [model])
      ..mpbModel = model
      ..confident = true
      ..buyback = buyback
      ..source = 'prix MPB réel';

Analysis analysis({double price = 100, double buyback = 200, CostBreakdown? costs, PhotoCheck? photos}) => Analysis(
    items: [item('Sony Alpha A6000', buyback)],
    price: price,
    defects: [],
    conditionHint: 'bon',
    shutterCount: null,
    warnings: [],
    costs: costs,
    photos: photos);

AdExtras ad({bool shippable = false, double lat = 48.8566, double lng = 2.3522}) =>
    AdExtras(city: 'Paris', zipcode: '75001', lat: lat, lng: lng, shippable: shippable);

void main() {
  group('marge nette', () {
    final s = NetSettings(homeLat: 48.8566, homeLng: 2.3522, kmCost: 0.15, maxKm: 30, feePct: 5, feeFixed: 0.7, shippingCost: 6);

    test('livraison : frais Leboncoin + envoi', () {
      final c = computeCosts(100, ad(shippable: true, lat: 45.76, lng: 4.83), s); // Lyon, loin
      expect(c.mode, 'livraison');
      expect(c.fees, closeTo(5.7, 0.001));
      expect(c.shipping, 6);
      final a = analysis(costs: c);
      expect(a.grossMargin, 100);
      expect(a.margin, closeTo(100 - 11.7, 0.001));
    });

    test('main propre proche : trajet aller-retour × coût/km, sans frais', () {
      final c = computeCosts(100, ad(lat: 48.90, lng: 2.35), s); // ~6 km
      expect(c.mode, 'main propre');
      expect(c.fees, 0);
      expect(c.tooFar, isFalse);
      expect(c.travel, closeTo(2 * c.distanceKm! * 0.15, 0.001));
    });

    test('main propre seulement et trop loin : alerte', () {
      final c = computeCosts(100, ad(lat: 45.76, lng: 4.83), s);
      expect(c.tooFar, isTrue);
    });

    test('livraison possible mais main propre moins chère si proche', () {
      final c = computeCosts(100, ad(shippable: true, lat: 48.87, lng: 2.35), s); // ~2 km
      expect(c.mode, 'main propre');
    });

    test('prix max tient compte des frais', () {
      final c = computeCosts(100, ad(shippable: true, lat: 45.76, lng: 4.83), s);
      final max = maxPriceFor(200, 30, c);
      // max × 1,05 + 0,7 + 6 = 170
      expect(max * 1.05 + 0.7 + 6, closeTo(170, 0.001));
      expect(maxBuyPrice(analysis(costs: c), 30)! <= max, isTrue);
    });
  });

  group('état le plus bas', () {
    test('photos plus usées que l\'annonce', () => expect(lowestCondition('excellent', 'well-used'), 'well-used'));
    test('annonce plus usée que les photos', () => expect(lowestCondition('good', 'like-new'), 'good'));
    test('état visuel inconnu ignoré', () => expect(lowestCondition('excellent', 'inconnu'), 'excellent'));
  });

  group('achat auto strict', () {
    final net = NetSettings(feePct: 5, feeFixed: 0.7, shippingCost: 6);
    final b = BuySettings(minNetMargin: 60, maxPrice: 200);
    PhotoCheck goodPhotos() => PhotoCheck(images: ['a', 'b'], coherent: 'oui', visualCondition: 'excellent');
    HistoryEntry entry(Analysis a, {bool shippable = true}) => HistoryEntry(
        id: 'radar_1', date: DateTime(2026), url: 'u', title: 'Sony A6000', adPrice: a.price, description: '',
        attributes: {}, analysis: a, extras: AdExtras(images: ['a', 'b'], shippable: shippable));
    Analysis sure({double price = 100, double buyback = 250, PhotoCheck? photos}) {
      final a = analysis(price: price, buyback: buyback, photos: photos ?? goodPhotos());
      a.aiVerdict = 'oui';
      for (final i in a.items) {
        i.prudentBuyback = buyback - 20;
      }
      return a;
    }

    test('tout est sûr : achat possible', () => expect(buyBlockReason(entry(sure()), b, net), isNull));
    test('défaut majeur : refus', () {
      final p = PhotoCheck(images: ['a', 'b'], coherent: 'oui', visualCondition: 'good', defects: [PhotoDefect('rayure', true, 0)]);
      expect(buyBlockReason(entry(sure(photos: p)), b, net), contains('défaut majeur'));
    });
    test('« écran cassé » est majeur même marqué mineur', () {
      final p = PhotoCheck(images: ['x'], coherent: 'oui', defects: [PhotoDefect('écran cassé', false, 1)]);
      expect(p.hasMajorDefect, isTrue);
    });
    test('photos en doute : refus', () {
      final p = PhotoCheck(images: ['a', 'b'], coherent: 'doute', visualCondition: 'good');
      expect(buyBlockReason(entry(sure(photos: p)), b, net), contains('photos'));
    });
    test('verdict pas « oui » : refus', () {
      final a = sure()..aiVerdict = 'doute';
      expect(buyBlockReason(entry(a), b, net), contains('vérification'));
    });
    test('pas de livraison : refus', () => expect(buyBlockReason(entry(sure(), shippable: false), b, net), contains('livraison')));
    test('marge nette trop faible : refus', () {
      // 250 − (150 + 7,5 + 0,7 + 6) = 85,8 → OK ; 200 − 164,2 = 35,8 → refus
      expect(buyBlockReason(entry(sure(price: 150, buyback: 200)), b, net), contains('marge nette'));
    });
    test('trop cher : refus', () => expect(buyBlockReason(entry(sure(price: 190, buyback: 400)), b, net), contains('max')));
  });

  group('tableau de bord du Stock', () {
    final now = DateTime(2026, 10, 10);
    final deals = [
      Deal(entryId: 'a', title: 'A', url: '', boughtPrice: 100, fees: 10, boughtAt: DateTime(2026, 9, 1),
          estimated: 200, status: DealStatus.paid, soldPrice: 190, soldAt: DateTime(2026, 10, 2), soldWhere: 'MPB'),
      Deal(entryId: 'b', title: 'B', url: '', boughtPrice: 50, boughtAt: DateTime(2026, 8, 1),
          estimated: 100, status: DealStatus.paid, soldPrice: 110, soldAt: DateTime(2026, 9, 2), soldWhere: 'MPB'),
      Deal(entryId: 'c', title: 'C', url: '', boughtPrice: 80, boughtAt: DateTime(2026, 10, 1), estimated: 150),
    ];
    final st = StockStats.from(deals, now: now);
    test('bénéfices', () {
      expect(st.count, 3);
      expect(st.done, 2);
      expect(st.totalProfit, 80 + 60);
      expect(st.monthProfit, 80);
      expect(st.avgProfit, 70);
      expect(st.best!.title, 'A');
    });
    test('précision estimé vs payé', () {
      expect(st.precisionCount, 2);
      expect(st.precisionDiff, 0); // (−10 + 10) / 2
      expect(st.precisionPct, closeTo((5 + 10) / 2, 0.001));
    });
    test('export CSV', () {
      final csv = dealsCsv(deals);
      expect(csv.split('\n').length, 4);
      expect(csv, contains('Payé par MPB'));
    });
  });
}
