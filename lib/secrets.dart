/// Clés API Gemini (appli strictement personnelle — garder le dépôt PRIVÉ).
/// La première est utilisée ; les suivantes servent de secours si une clé
/// est invalide ou révoquée.
const List<String> geminiKeys = [
  'AQ.Ab8RN6LcYqBfbAhLFxLaCdSRr9OVOVP2gIgghkUP-eGLxQSNww',
  'AQ.Ab8RN6J13l0IOTsTS7MAIL4mlq53VRtbTOiXpJ5pM7N7SaDnHA',
  'AQ.Ab8RN6JcBKYaispNpXeU_eFTsqUj_GkGu8mW6JMx4s67nmcb0g',
  'AQ.Ab8RN6IV8Ru7ug37Q2Qgz3VIc0vnvTFmC99pg_Ke_dNRE3Qctw',
  'AQ.Ab8RN6LsjJ7vHslnJ7GVXrqF2Hlf-rpFxwh7-H9ZCg2qWHX9Kg',
];

/// Modèle demandé, puis modèle de repli si l'alias n'est pas reconnu.
const List<String> geminiModels = [
  'gemini-flash-lite-latest',
  'gemini-3.5-flash-lite',
];
