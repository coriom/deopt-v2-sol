# DEOPT_PERPS_V22_MKT1_S1_RESULT

11 novembre 2026 — Base Sepolia (84532). **MKT1 S1 programmée ; aucun marché créé.**
Cette opération est distincte de l'exécution atomique S2, qui reste non autorisée.

## Préflight

- Le préflight indépendant [V22](tools/perps_v2_cutover/prepare_atomic_governance_v22.py)
  a vérifié au bloc **57 272 026**
  (`0x2b42b523e721c67bf07c334ed57ebcaa21bbe0681d2e925faeec675eded7077f`)
  le receipt canonique de C02 S1 `0xc394fa4952f0a346a0a8c7f94789dbb8d0597b4205874880a5ae09f7529f38b6`
  et son unique `TransactionQueued`.
- Safe OPS : nonce **44**, seuil **2/3**, propriétaires attendus, guard nul,
  modules vides. Timelock : Safe proposer/exécuteur et propriétaire/guardian,
  exécuteur public absent, délai minimal **86 400 s**, queue non pausée.
  Hashes des bytecodes D1–D4, D6, Safe, Timelock et MultiSendCallOnly conformes
  aux références V21 ; Registry D1 sans marché, prochain ID 1 ; pauses D4/D6
  actives. Ancienne MKT1 toujours en file, non exécutée.
- C02 nouvelle en file, MKT1 nouvelle absente ; ETA
  **14 novembre 2026 à 12:00 UTC** (`1794657600`) conserve la marge de
  programmation prévue. Payload MKT1 identique octet pour octet au paquet V21.
  Hash Safe au nonce 44 : `0xd8dae05f3362d3dea6fd23497c14ec61ed3db2e2a78c4361e2192e1d60290e84`.
- Simulation fork au bloc **57 269 793** :
  `RPC_URL=https://sepolia.base.org V22_FORK_BLOCK=57269793 forge test --match-path test/perp/PerpsV22Mkt1S1Fork.t.sol -vv`
  → **1/1 PASS**, gas Safe simulé 66 655. Les approbations `vm.prank`
  sont exclusivement locales et ne sont pas des signatures Safe.
  La simulation Safe Transaction Builder a également réussi :
  `https://dashboard.tenderly.co/public/safe/safe-apps/simulator/943d469f-fb02-4252-b878-386744766b9f`.
  Le `forge build` global a été interrompu après une compilation longue
  pour préserver les ressources WSL ; le test ciblé a compilé et exécuté
  le contrat de simulation. Aucun contrat de production n'a été modifié.

## Signatures, transaction et receipt

- Safe Transaction Builder : **une seule** opération `CALL`,
  `queueTransaction(D1, 0, setMarketStatus(1,false,false), 1794657600)`
  vers le Timelock `0xa67f8E8E673ce4bb2Fb563B0e6E9FA8F70E3b588`.
  Valeur ETH 0, nonce 44, `safeTxGas=baseGas=gasPrice=0`,
  `gasToken=refundReceiver=address(0)`. Calldata hexadécimal comparé
  intégralement au paquet V21. Le hash affiché par Safe correspond au hash RPC.
- Signatures réelles Safe **2/2** : `0xb9F8…6d06`, puis
  `0x0E7D…a35d`. Safe affiche une exécution réussie.
- Transaction publique :
  `0xd0fa2915b6db15415b97eaf45987625f8ff94f95b42d9c748cb8414de3a8d1de`.
  Receipt `status=0x1` au bloc **57 272 581**,
  hash `0x92f13878f1b22941af8a903f345735059c392e45b4489cc47c551238bb5d0bc5`,
  **286 912 gas**. Le hash de bloc correspond au bloc canonique relu par RPC.
- La transaction publique utilise une enveloppe de relayage
  (destinataire `0xdb9b1e94b5b69df7e401ddbede43491141047db3`,
  sélecteur `0xcef6d209`, valeur ETH 0). Sur les cinq logs du receipt,
  **un seul** `TransactionQueued` vient du Timelock pour
  `0xd5df44f7f5a0ff062c46766587c194a0bc1a706c66555b8b01613e09bc5207a8`.
  Il porte la cible D1, valeur 0, l'ETA prévue et le calldata exact.
  Le Safe émet `ExecutionSuccess` pour le hash attendu.
  Deux autres émetteurs sont externes à D1–D6 ; aucun log D1–D6.

## Postflight canonique

Le vérificateur [V22](tools/perps_v2_cutover/verify_atomic_governance_v22_postflight.py)
a lu un même bloc **57 274 112**
(`0xf04b02f4bf5f516e4226322625d1a3eca3214c33057337b16247b52d29f3229e`) :

| Contrôle | Résultat |
| --- | --- |
| Receipt C02 S1 encore canonique | PASS |
| Receipt MKT1 S1 et un seul `TransactionQueued` exact | PASS |
| Nonce Safe | **45** |
| Nouvelle C02 / nouvelle MKT1 | **queued / queued** |
| Prêtes avant l'ETA | **false / false** |
| Ancienne MKT1 | **toujours queued**, sans exécution |
| D1 | **0 marché**, prochain ID **1** |
| D4 | Trading, liquidation, funding et collatéral **pausés** |
| D6 | **pausé** |

Empreinte SHA-256 du résultat JSON local :
`162470ba64fac492fbacafc7ac46336db630048fc1fdf7a8cafecb4763f146b4`.

## Prochaine porte de gouvernance

**Ne pas exécuter C02 seule, MKT1 seule ou l'ancienne MKT1.**
Le batch S2 Safe MultiSendCallOnly requiert une **autorisation distincte**,
après l'ETA et un nouveau préflight RPC : paire exacte toujours queued/ready,
nonce et signatures Safe frais, marché absent, pauses D4/D6 maintenues,
exécutants distants requalifiés, simulation de revert et payload de deux
appels seulement. Si un de ces contrôles échoue, STOP sans transaction.
Après S2, le marché 1 doit exister et être **INACTIVE**.
