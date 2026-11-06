# DEOPT_OPTIONS_SETTLEMENT_POLICY_V10_FINAL

Périmètre : **proposition économique non approuvée** pour les nouvelles séries Call Base Sepolia (84532). Prototype local, tests Foundry et fork épinglé uniquement. Aucune transaction, propriété, pointeur Vault, fonds ou configuration hébergée modifiés.

## Règle proposée

1. Le prix principal est le **dernier round Chainlink au plus tard à l'échéance**, prouvé par son round immédiatement suivant, dans la même phase, dont le timestamp est strictement après l'échéance. Les deux IDs doivent être consécutifs, `answeredInRound` doit correspondre à l'ID demandé, les prix doivent être positifs, les timestamps cohérents et le round suivant déjà publié. Un trou, une transition de phase ou l'absence du round suivant bloque le règlement. Le prix retenu est celui du round précédent.
2. La paire est admissible si le round précédent est au plus à **1 500 s** avant l'échéance et le suivant au plus à **1 500 s** après. Les décimales sont normalisées en 1e8. Ces bornes sont plafonnées par le constructeur et ne peuvent pas être élargies administrativement.
3. **Pyth Core est un repli**, jamais un remplacement opportuniste d'un round Chainlink admissible. Il faut fournir la paire Chainlink adjacente et temporellement encadrante prouvant qu'au moins une borne de 1 500 s est dépassée. La preuve Pyth doit être acceptée par le contrat Core déployé via `parsePriceFeedUpdatesUnique`, ce qui authentifie la première mise à jour pour le feed et la fenêtre `[expiry, expiry + 1 500 s]`. Son ID, son prix positif, son timestamp non futur, son exposant et sa confiance au plus à 100 bps sont vérifiés. Si la paire Chainlink manque ou traverse une phase, **pas de repli automatique** : la preuve d'inadmissibilité manque.
4. Une preuve Pyth authentique divergente de **plus de 100 bps** peut signaler un litige pendant les **48 h** suivant une proposition Chainlink. Elle **ne modifie pas le prix retenu** lorsque la preuve principale est admissible. La divergence de deux prix autour d'une échéance fixe ne démontre pas à elle seule que le round pré-échéance est invalide. La priorité Pyth de V9 est rejetée : elle aurait déplacé le payoff d'un Call vers le haut ou le bas selon un mouvement post-échéance, au bénéfice du long ou du short. Le seuil de 100 bps est un signal d'exploitation, pas une permission de choisir une source.
5. La première proposition admissible fixe l'horloge. Une seule preuve de divergence est enregistrée, sans extension du délai ni nouvelle proposition. Après 48 h, `resolve` choisit mécaniquement Chainlink, ou Pyth uniquement si la proposition initiale a établi le repli. `finalize` écrit une seule fois dans le Registry. En absence de preuve admissible, le règlement reste en attente ; aucun prix libre, dernier prix connu ou intervention administrateur n'est substitué.

Cette politique **ne garantit pas un règlement borné dans le temps** : indisponibilité durable des rounds ou des payloads authentiques immobiliserait les obligations et le collatéral. Une autre issue économique exige un mécanisme et une approbation distincts. Les fenêtres de 25 minutes sont des maxima candidats, pas la preuve qu'un feed testnet représente exactement le prix de l'échéance ; les deux contreparties supportent le risque d'un mouvement dans ces fenêtres.

## Séries historiques et propriété

Au bloc fork 55 041 332, le Registry historique contient des séries, dont une série Call avec **sept positions short agrégées** et échéance au 1er janvier 2030. L'ancien propriétaire peut encore fixer son prix positif selon les règles historiques du Registry. Le vérificateur V9 excluait ces séries et, s'il prenait la propriété, aurait supprimé leur chemin de règlement. V10 ajoute donc `LegacySeriesPresent` à `acceptRegistryOwnership` : **la prise de propriété du Registry actuel échoue** tant qu'il contient une série. Le test fork prouve le refus et la conservation du propriétaire, de l'open interest et des montants agrégés du Vault au bloc épinglé. La valeur historique de 224 066 mUSDC provient du relevé V8 ; elle n'est pas une mesure actuelle.

Chemin distinct à qualifier avant toute bascule : conserver le Registry historique et ses droits de règlement pour ses séries ; affecter les nouvelles séries à une infrastructure de Registry et de moteur réellement séparée, ou présenter une passerelle legacy strictement bornée aux IDs historiques dont les droits économiques seraient approuvés explicitement. Le premier choix implique une nouvelle intégration moteur/Vault à tester ; le second conserve le pouvoir historique de prix arbitraire **pour les anciennes positions uniquement** et doit être examiné comme hypothèse de confiance. Aucun de ces chemins n'est prouvé et approuvé aujourd'hui. **Ne pas proposer le transfert de propriété actuel.** Aucun changement de pointeur du Vault partagé n'est inclus ; ses usages non Options restent insuffisamment qualifiés.

## Preuves et limites

- `forge test --match-path test/unit/settlement/VerifiedOptionSettlementOwner.t.sol -j 1 -vv` : sélection primaire, repli prouvé par borne périmée, rejet de repli quand Chainlink est admissible, mauvais timestamp, délai fixe, double contestation/finalisation, absence de preuve.
- `python3 -B tools/options_v8_oracle_probe.py --fork-test` : tests sur blocs Base Sepolia épinglés ; **vrai feed Chainlink** pour une échéance locale synthétique et **vrai payload signé Pyth Core** vérifié par le contrat déployé. Le test de divergence forte emploie un prix Chainlink synthétique ; il n'est pas une divergence historique réelle. Le test de repli emploie une borne Chainlink synthétiquement périmée et un payload Pyth authentique ; la disponibilité de ce couple de preuves à une échéance future n'est pas démontrée.
- Le contrat déployé, les séries existantes, les droits économiques historiques, les flux de liquidation et le Vault partagé **ne sont pas modifiés**. La prise de propriété réelle et l'ouverture économique restent bloquées.
- Gas et frais : le repli V10 avec payload Pyth authentique et borne Chainlink synthétique périmée a consommé **152 634 gas** pour `proposePythFallback` sur fork, hors déploiement, résolution, Timelock et Safe. Les mesures V9 (~94 200 pour la proposition Chainlink, ~105 525 pour la preuve Pyth, ~99 776 pour résolution et finalisation) ne constituent pas un coût V10 complet. Le contrat Pyth déployé indiquait 0 wei de frais sur le fork V9, ce qui ne garantit pas les frais futurs.

Références de sémantique : [Pyth Core `parsePriceFeedUpdatesUnique`](https://api-reference.pyth.network/price-feeds/evm/parsePriceFeedUpdatesUnique) garantit `prevPublishTime < minPublishTime <= publishTime <= maxPublishTime` pour le feed demandé ; [Chainlink Historical Data](https://docs.chain.link/data-feeds/price-feeds/historical-data) décrit l'accès aux rounds historiques. Les garanties d'authenticité sont vérifiées dans le fork contre le contrat Pyth déployé, pas déduites d'une réponse HTTP.

## Décision opérateur demandée

| Paramètre | Proposition V10 | Conséquence à accepter |
| --- | --- | --- |
| Périmètre | Nouvelles séries Call Base Sepolia seulement | Aucun effet rétroactif sur les séries historiques. |
| Fenêtre Chainlink | 1 500 s avant et 1 500 s après | Plus large : prix pré-échéance plus périmé ; plus courte : davantage de règlements en attente. |
| Pyth Core | Première mise à jour dans les 1 500 s après échéance, repli uniquement si borne Chainlink adjacente prouve la péremption | Une variation post-échéance peut affecter les deux contreparties ; pas de repli si le prochain round manque. |
| Divergence | >100 bps : signal de litige, aucune bascule de source si Chainlink admissible | Évite le choix opportuniste de V9 ; un vrai défaut de Chainlink non détecté par les règles formelles exige une nouvelle politique. |
| Confiance Pyth | ≤100 bps | Une valeur trop stricte réduit la disponibilité ; trop large accroît l'incertitude du règlement. |
| Contestation | 48 h après première proposition, sans prolongation | Délai de visibilité, mais une preuve divergente n'a pas de veto sur une source principale formellement valide. |
| Aucune preuve | Règlement et collatéral en attente, sans borne automatique | Aucune extraction arbitraire ; risque d'immobilisation prolongée. |
| Historique | Registry et droits existants conservés ; transfert bloqué | Un chemin séparé doit être validé avant toute nouvelle série économique sur l'infrastructure historique. |

Quatre décisions restent distinctes : **(1)** approbation de cette politique économique ; **(2)** autorisation de pousser ce commit Git ; **(3)** approbation d'un paquet de déploiement Base Sepolia après résolution du chemin legacy et du Vault ; **(4)** autorisation d'ouverture économique après tests canoniques. Aucune n'est implicite.

## Verdict V10

`DETERMINISTIC_PRICE_SELECTION=PASS_LOCAL` ; `CHAINLINK_POLICY=PASS_LOCAL` ; `PYTH_UNIQUE_HISTORICAL_PROOF=PASS_FORK_CIBLE` ; `DIVERGENCE_RESOLUTION=PASS_LOCAL/PARTIAL_REAL_DIVERGENCE` ; `CHALLENGE_FINALITY=PASS_LOCAL` ; `LEGACY_SERIES_PRESERVATION=PARTIAL` ; `REGISTRY_OWNERSHIP_SAFETY=BLOCKED_FOR_CURRENT_REGISTRY` ; `SHARED_VAULT_SAFETY=PARTIAL` ; `ECONOMIC_PARAMETERS_FOR_APPROVAL=READY` ; `REMAINING_BLOCKERS=LEGACY_SETTLEMENT_PATH,VAULT_COMPATIBILITY,FUTURE_PROOF_AVAILABILITY`.

**Recommandation : soumettre uniquement la politique V10 des nouvelles séries Call à une approbation économique. Ne pas demander de transfert de propriété ni d'ouverture Options à ce stade.**
