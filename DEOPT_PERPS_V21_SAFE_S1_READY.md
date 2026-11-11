# DEOPT_PERPS_V21_SAFE_S1_READY

11 novembre 2026. **Décision technique : préparer uniquement la programmation C02 S1 de remplacement.** La politique V10 est approuvée pour Base Sepolia bêta, mais aucune action Safe n'est autorisée par cette revue. Aucun appel public signé ou diffusé n'a été effectué.

## Bloc de référence et préflight

Base Sepolia `84532`, bloc **57 250 691**, hash `0x50b3b12723e04d7228fffaaefb31a52f331de91d19aa6229fbfdd9d04a43408e`, timestamp **2026-11-11 04:40:07 UTC**. Le générateur de paquet a lu tous les getters au même bloc et a comparé les hashes de bytecode D1-D4, D6, Safe, Timelock et MultiSendCallOnly aux références déjà validées. Le paquet V10 d'origine avait l'empreinte attendue `40bf7c13bfe839e23bd8a257a045969ad8de56f58c53a0be56c9049eca79937f`.

| Verdict | Preuve |
| --- | --- |
| OLD_C02_STATUS **PASS** | Ancienne opération `0x9e10ee1c04280e36ba1d7144b5abd2d1a48b08fac54087bd5e7090d91030913e` encore marquée queued, mais `isOperationReady=false` après le 8 novembre 12:00 UTC. D1 compte zéro marché, prochain ID 1. |
| OLD_MKT1_RISK **PASS, sans annulation** | Ancienne MKT1 `0x9d2bd83ac8d34252fa2418e5b403a716e0131121fd14dad25a112220f7eef268` encore queued/ready jusqu'au 15 novembre 12:00 UTC inclus. `setMarketStatus(1,false,false)` échoue si le marché 1 est absent ; après création atomique, son exécution simulée maintient INACTIVE. Elle ne peut ni créer ni réactiver le marché. Ne jamais l'exécuter sur Base Sepolia. |
| SAFE_CURRENT_STATE **PASS au bloc** | Safe `0xA6B9Bb5c7B26B33cfD28C6F5A79B3c527fDdcD46`, version 1.4.1, nonce 43, seuil 2/3, les trois propriétaires connus, modules vides, guard nul. Hash de code conforme. |
| TIMELOCK_CURRENT_STATE **PASS au bloc** | Timelock `0xa67f8E8E673ce4bb2Fb563B0e6E9FA8F70E3b588`, propriétaire et guardian Safe, Safe proposer/exécuteur, exécuteur zéro absent, queue active, délai 86 400 s. D1 appartient au Timelock, qui reste market creator ; création et configuration D1 non pausées. |
| V10_POLICY_COMPATIBILITY **PASS technique** | Même `createMarket` puis `setMarketStatus(1,false,false)` que V10 ; même Timelock et MultiSendCallOnly ; aucun salt ni prédécesseur natif dans ce Timelock. Interdiction de C02 isolée toujours hors chaîne : un Safe 2/3 pourrait techniquement l'exécuter seul. D4 quatre pauses et D6 pause toujours actives. |
| ATOMIC_EXECUTION_SIMULATION **PASS local** | Anvil fork au bloc indiqué, trois tests Foundry réussis. Les approbations Safe sont **synthétiques** (`vm.prank`), sans signature authentique. Événements : `MarketCreated`, exécution C02, `MarketStatusUpdated(INACTIVE)`, exécution MKT1 dans cet ordre. |
| FINAL_MARKET_STATE **PASS fork seulement** | Après batch : un seul marché, ID 1, `exists=true`, `isActive=false`, `isCloseOnly=false`; les deux nouvelles opérations consommées, ancienne MKT1 encore queued ; D4/D6, racine de frais D2 et configuration de saisie D3 inchangées. Une panne injectée du second appel annule toute la transaction : aucun marché, opérations toujours queued, nonce Safe inchangé. |

## Paquet conditionnel

ETA proposée **2026-11-14 12:00:00 UTC** (`1794657600`). Pour conserver douze heures de marge au-delà du délai minimum, **les deux programmations doivent être minées avant le 13 novembre 00:00 UTC**. Après ce seuil, régénérer ETA, IDs, calldata et hashes ; ne pas forcer le paquet actuel.

| Action distincte | Cible Safe | Opération Safe | Nonce conditionnel | ID Timelock | Hash Safe conditionnel |
| --- | --- | --- | ---: | --- | --- |
| Nouvelle C02 S1 | Timelock | CALL, valeur 0, `queueTransaction(D1,0,createMarket,ETA)` | 43 | `0xee2e6d5e45752f49a06007becb4b5fba8a1c906a4e45b72c6e109b8ef014807f` | `0x6116c8250c4602fb17b9a93faf582f0d52574a78ece1e7504545cf5f83c96784` |
| Nouvelle MKT1 S1 | Timelock | CALL, valeur 0, `queueTransaction(D1,0,setMarketStatus(1,false,false),ETA)` | 44 | `0xd5df44f7f5a0ff062c46766587c194a0bc1a706c66555b8b01613e09bc5207a8` | `0xd8dae05f3362d3dea6fd23497c14ec61ed3db2e2a78c4361e2192e1d60290e84` |
| Batch S2 | MultiSendCallOnly | DELEGATECALL, valeur 0, exactement deux CALL ordonnés au Timelock | 45 | Les deux IDs ci-dessus consommés | `0x4ddefb02fc131b134be68507147c586391f5e00f62757c7c0ae9147efbe8125f` |

Les hashes Safe utilisent `safeTxGas=baseGas=gasPrice=0`, `gasToken=refundReceiver=0`. Ils ne valent **ni signature ni autorisation** et deviennent caducs dès qu'un nonce, un champ gas, un contrat, l'ETA ou le payload change. Les calldatas exacts, leurs keccak256 et l'ensemble des lectures sont dans [le paquet conditionnel](artifacts/perps_v2_replacement_deployment/c02_atomic_governance_v21_conditional.json) (SHA-256 `8af8f6e97a07ae64914896eaf2887f55d5756e2d08ca746d64aaafc4592c938b`). [Le fichier Safe Builder S1](artifacts/perps_v2_replacement_deployment/c02_s1_safe_builder_v21_unsigned.json) contient **une seule** programmation, aucune signature (SHA-256 `530d38933a5727c1ff27883c50715a7989cbd3e7f70918d0f7614071542983b0`). Les autres actions nécessiteront leurs propres autorisations, après postflight canonique de l'action précédente.

Gas mesuré pour les seuls `execTransaction` du Safe avec approbations synthétiques sur fork : C02 S1 **69 809**, MKT1 S1 **49 392**, batch S2 **380 632**. Ces valeurs sous-estiment possiblement la transaction réelle avec signatures ECDSA. Candidats de limite externe : **250 000**, **250 000**, **1 000 000** respectivement. Avant chaque action, Safe UI et RPC doivent réestimer le gas du payload exact. Ne pas traiter les candidats comme des limites approuvées ou un coût payé.

## Commandes et conditions d'arrêt

Depuis `deopt-v2-sol`, la préparation locale **sans signature ni diffusion** se reproduit par :

```bash
block=$(cast block latest --field number --rpc-url https://sepolia.base.org)
PYTHONDONTWRITEBYTECODE=1 python3 tools/perps_v2_cutover/prepare_atomic_governance_v21.py \
  --block "$block" --eta 1794657600 \
  --out /tmp/deopt-v21-fresh-package.json \
  --builder-out /tmp/deopt-v21-fresh-c02-s1-unsigned.json
```

Résultat attendu avant la limite de programmation : `V21_PREFLIGHT=PASS`, même ID C02 et nouveau snapshot. Si le nonce ou l'ETA dérive, **ne pas utiliser** les hashes ci-dessus ; régénérer et examiner le paquet avant toute demande de signature. Le script échoue fermé sur dérive des autorités, bytecodes, pauses, marchés, opérations et délai minimum. Il ne contient ni `cast send`, ni clé, ni diffusion. Le résultat attendu de la **future** action S1, si elle est autorisée séparément, est un seul `TransactionQueued` pour le nouvel ID C02, Safe nonce +1, marché toujours absent, D4/D6 inchangées ; sinon STOP et aucune MKT1 S1.

Simulation reproductible sur fork local (uniquement transactions Anvil) :

```bash
anvil --fork-url https://sepolia.base.org --fork-block-number 57250691 \
  --chain-id 84532 --host 127.0.0.1 --port 18547 --silent
# Dans un autre terminal :
RPC_URL=http://127.0.0.1:18547 forge test \
  --match-path test/perp/PerpsV21ResumeFork.t.sol -vv
```

STOP avant toute action Safe si les propriétaires, seuil, nonce, guard, modules, rôles, code, pause, état D1, ETA, calldata ou gas diffèrent ; si une nouvelle opération est déjà queued ; si le Safe UI montre un autre target, une valeur non nulle, une autre opération ou un sous-appel supplémentaire. Avant le batch S2, revalider séparément l'isolement des exécutants distants et tous les gardes économiques V10. L'ancienne MKT1 n'est pas une étape de récupération ; si la nouvelle paire échoue, ne pas exécuter C02 seule.

**OPERATOR_APPROVAL_REQUIRED :** autorisation distincte pour **nouvelle C02 S1 uniquement**, ciblant le Timelock et l'ID exact ci-dessus, après un préflight frais et une revue Safe UI. Cette revue n'autorise ni MKT1 S1, ni S2, ni trading.
