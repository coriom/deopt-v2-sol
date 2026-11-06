# DEOPT_OPTIONS_SETTLEMENT_FINAL_POLICY_V9

Périmètre : prototype Solidity local, lectures RPC Base Sepolia et tests Foundry sur forks épinglés. Aucune transaction publique, signature Safe, modification du Vault ou push GitHub.

## Décision technique

Le Registry historique peut finaliser un prix positif arbitraire par son propriétaire ou son opérateur de règlement. Le prototype V9 conserve la prise de propriété exclusive V8 : après transfert, l'ancien propriétaire et le gardien ne peuvent plus appeler les chemins de prix ni rouvrir librement la création. **Le Registry en ligne n'a pas été modifié et reste donc exposé à son ancien modèle de confiance.** Les anciens prix déjà finalisés ne pourraient pas être corrigés par ce propriétaire.

La machine V9 a cinq états : `PRICE_UNAVAILABLE`, `PRICE_PROPOSED`, `CHALLENGED`, `RESOLVED`, `FINALIZED`. Un premier prix Chainlink admissible fixe un délai de contestation immuable. Une preuve Pyth Core authentifiée et matériellement divergente peut remplacer ce prix selon la règle candidate ci-dessous. Une seule contestation est acceptée ; aucune annulation ni nouvelle proposition ne peut remettre l'horloge à zéro. Après le délai, `resolve` sélectionne mécaniquement la source, puis `finalize` écrit une seule fois dans le Registry. Les fonctions sont permissionless hormis la création de séries et les fonctions administratives restreintes. Le contrat fige le chain ID de son déploiement et vérifie l'ID du feed, l'actif, l'asset de règlement et l'échéance via la série immuable du Registry.

Cette machine résout le blocage V8 causé par une contestation **admissible**. Elle ne fabrique pas de prix lorsque Chainlink n'offre pas de paire de rounds admissible : l'état demeure `PRICE_UNAVAILABLE`, les obligations et le collatéral restent en attente. Une preuve Pyth seule n'est actuellement pas un chemin de fallback, car l'absence d'un round Chainlink admissible n'est pas prouvable avec un simple identifiant de round fourni par l'appelant. Un fallback Pyth sans preuve de cette absence permettrait de contourner la priorité annoncée. Une indisponibilité permanente, un changement de phase ou une panne du séquenceur peuvent donc laisser le règlement bloqué. Aucun prix administrateur, dernier prix connu ou pouvoir Safe de substitution n'est ajouté.

## Preuves oracle obtenues

- Chainlink : sur le fork au bloc **55 073 290**, le feed ETH/USD déployé renvoie les rounds consécutifs `18446744073709842478` et `18446744073709842479`, aux timestamps `1793934493` et `1793934812`, encadrant l'échéance locale `1793934781`. Le premier prix est `224042789828` en 1e8. L'expiration est celle d'une **série synthétique locale**, pas d'une position historique DeOpt.
- Pyth Core : un payload public de **631 octets** provient de la transaction Base Sepolia `0xf9ac3c02fb1626391f372b269a19acf69c075e14415a93ff128c64ef51162426`, confirmée au bloc **55 064 570**, avec événement du contrat `0x5f52e4dbea21f5b23523b6e20d50c29ae0a4eb83` pour l'ID ETH `0xff61491a931112ddf1bd8147cd1b641375f79f5825126d665480874634fd0ace`. Empreinte SHA-256 du payload : `cdc043dd46d79986b3c3d7a6b5c0a41396d0ca1a91ffd812e9b27674a07acbd7`. Sur fork, **le vrai contrat Pyth** accepte `parsePriceFeedUpdatesUnique` pour le timestamp `1793934781` et refuse un autre feed et une fenêtre commençant après ce timestamp. Prix `223785865763`, confiance `229134237` en unités du feed ; divergence par rapport à Chainlink **11,47 bps**, confiance **10,24 bps**.
- Le test de concordance avec **deux vraies sources** refuse à juste titre une contestation sous 100 bps. Un autre test emploie la même preuve Pyth réellement signée mais un feed Chainlink **synthétique et volontairement divergent** : il valide la branche `CHALLENGED → RESOLVED → FINALIZED`, sans prétendre que deux oracles réels ont divergé lors de cet essai.
- Le `getUpdateFee` du contrat Pyth épinglé était **0 wei** pour ce payload ; cela ne garantit ni les frais futurs ni l'accès continu à des payloads signés. L'extraction depuis une transaction publique permet ce test sans clé API. La [documentation Pyth Core](https://api-reference.pyth.network/price-feeds/evm/parsePriceFeedUpdatesUnique) spécifie l'unicité du premier update de la fenêtre ; la [documentation Pyth](https://docs.pyth.network/pro/pyth-core-upgrade) indique que l'accès Hermes exige désormais une clé API. Les payloads Pyth Pro ne sont pas supposés interchangeables avec ceux de Pyth Core.
- Les rounds Chainlink de phases différentes échouent en sécurité ; aucun parcours on-chain non borné n'est effectué. La [documentation Chainlink](https://docs.chain.link/data-feeds/price-feeds/historical-data) précise que les phases changent le sens des identifiants de rounds. La liste officielle des [feeds de disponibilité du séquenceur](https://docs.chain.link/data-feeds/l2-sequencer-feeds) mentionne Base Mainnet, sans adresse Base Sepolia vérifiée ici. Aucun contrôle historique du séquenceur testnet n'est revendiqué.

## Politique économique candidate — non approuvée

| Paramètre | Valeur proposée | Motif et risque |
| --- | --- | --- |
| Source principale | Dernier round Chainlink `updatedAt ≤ expiry`, suivi du round immédiatement suivant `updatedAt > expiry`, même phase | Sélection non discrétionnaire et deux appels bornés ; phase manquante ou saut de round bloque le règlement. |
| Fenêtre Chainlink | Au plus 1 500 s avant et 1 500 s après l'échéance | Couvre les intervalles observés sur le feed testnet ; une fenêtre plus large augmente le risque de prix périmé, une fenêtre plus courte immobilise plus souvent les positions. |
| Source de contestation | Premier update Pyth Core signé dans `[expiry, expiry + 1 500 s]`, feed fixé dans le constructeur | La preuve cryptographique empêche un prix libre ; disponibilité future des payloads non garantie. |
| Divergence matérielle | Strictement plus de 100 bps par rapport au prix Chainlink | Sous le seuil, Chainlink reste prioritaire ; au-dessus, Pyth devient prioritaire. Un seuil faible favorise des changements de source dus à la volatilité normale ; un seuil élevé laisse passer un prix Chainlink dégradé. |
| Confiance Pyth | Au plus 100 bps du prix Pyth positif | Rejette des observations trop incertaines ; peut réduire la disponibilité. |
| Délai de contestation | 48 h après la première proposition vérifiée, sans prolongation | Donne une fenêtre de publication de preuve ; une fenêtre trop courte réduit les recours, une longue retarde acheteurs et vendeurs. Le délai ne court pas tant qu'aucune preuve principale n'est disponible. |
| Source gagnante | Chainlink sans contestation admissible ; **Pyth gagne si sa preuve est authentique, dans la fenêtre et divergente >100 bps** | Règle déterministe mais **choix économique substantiel** : le prix Pyth post-échéance peut avantager une contrepartie lors d'une forte variation. Approbation explicite requise. |
| Historique absent | Aucune finalisation, obligations et collatéral conservés | Protège de la fixation arbitraire mais peut immobiliser les deux contreparties sans borne. Toute autre issue exige une nouvelle source authentifiée et une politique approuvée. |

Ces paramètres sont des propositions, pas des valeurs activées en production. Le Timelock déployé affichait `minDelay=86 400 s` au bloc **55 076 609** ; ses opérations de transfert de propriété resteraient soumises à ce délai et à des autorisations Safe distinctes. La fenêtre de contestation de 48 h commence seulement après une proposition admissible et ne remplace pas le Timelock.

## Positions historiques et Vault partagé

Une lecture ciblée au bloc **55 077 228** montre la série Call historique `24145907678156652148089862289363692212069910767044828147380657249455352740183` active, avec **sept positions short agrégées** et échéance **1er janvier 2030 UTC**. Appliquer silencieusement la nouvelle règle à ces positions changerait leur règlement attendu. V9 marque donc uniquement les séries créées **après** la prise de propriété comme éligibles ; aucune série historique ne peut être proposée ou finalisée via la nouvelle machine. Une fonction Timelock crée seulement une nouvelle série Call européenne sur un sous-jacent et un collatéral configurés, puis la met **INACTIVE dans la même transaction** et referme les permissions temporaires de création. Sur fork, la série historique reste inéligible et le solde agrégé du Vault et l'open interest short restent inchangés.

Cela protège les positions existantes d'un changement rétroactif, mais **ne résout pas encore leur règlement à l'échéance**. Une politique contractuelle séparée, examinant les droits des deux contreparties, est indispensable avant toute prise de propriété réelle. Le prototype n'est pas une migration autonome des anciennes séries. Les tests V8 du garde de retrait sur InsuranceFund et deux comptes Perps restent pertinents, mais ne prouvent pas tous les chemins de liquidation, transfert interne, stratégie ou retrait du Vault partagé. Aucun changement de pointeur n'est proposé.

Le transfert de propriété est à sens unique dans ce prototype : le Safe et le Timelock n'ont aucun raccourci de prix ou de reprise discrétionnaire après acceptation. Il faut donc un plan de récupération vérifié avant déploiement. Le fork vérifie que le pointeur `MarginEngine.optionRegistry()` reste le Registry historique après la prise de propriété ; ce pointeur n'a pas de setter dans le code MarginEngine examiné. `OptionMatchingEngine.setRegistry` et `RiskGovernorAdmin.setOptionRegistryTarget` existent, mais ne modifient pas ce pointeur du moteur de règlement ; ils restent des surfaces de gouvernance distinctes à surveiller. Les helpers historiques de `RiskGovernorQueue` qui ciblent directement le Registry ne fonctionneraient plus ; les appels encore autorisés devront cibler le vérificateur. L'allowlist V9 interdit les changements de paramètres de risque du Registry et l'activation des séries historiques ; elle permet au Timelock d'activer ultérieurement une nouvelle série éligible par une opération distincte. Aucune activation n'a été exécutée sur Base Sepolia.

## Tests reproductibles et coûts

```bash
cd /home/corio/DEOPT/deopt-v2-sol
forge test --match-path test/unit/settlement/VerifiedOptionSettlementOwner.t.sol -j 1 -vv
python3 -B tools/options_v8_oracle_probe.py --fork-test
python3 -B tools/options_v9_extract_pyth_fixture.py  # optionnel : reconstruit le fixture depuis la transaction publique
forge build --skip test -j 1
```

`RPC_URL` est lu par les scripts depuis la configuration locale existante, sans être imprimé. V9 : **6 tests unitaires et 5 tests fork PASS**. Le test fork du litige Pyth consomme environ **105 525 gas** pour la contestation, **99 776 gas** pour résolution + finalisation ; la proposition avec le vrai feed Chainlink consomme environ **94 200 gas** dans le scénario local. Ce sont des mesures de fonctions sur fork, hors frais de déploiement, Timelock, Safe et gas payé au réseau public. Aucun budget monétaire n'est annoncé.

## Verdicts

| Champ | Verdict | Preuve et limite |
| --- | --- | --- |
| `DETERMINISTIC_SETTLEMENT` | **PARTIAL** | Machine codée et testée ; priorité Pyth après divergence soumise à approbation. |
| `CHAINLINK_REAL_PROOF` | **PARTIAL** | Deux rounds réels encadrent une échéance de série locale ; série DeOpt 2030 non testable aujourd'hui. |
| `PYTH_REAL_SIGNED_PROOF` | **PASS ciblé** | Payload public authentifié par le contrat Pyth Core déployé sur fork ; disponibilité future inconnue. |
| `DISPUTE_RESOLUTION` | **PARTIAL** | Litige résolu avec un vrai payload Pyth et un prix Chainlink synthétique divergent ; pas de divergence réelle des deux sources prouvée. |
| `BOUNDED_CHALLENGE` | **PASS** | Un délai fixe, une contestation, aucune annulation/reproposition et finalisation unique. |
| `NO_PRICE_AVAILABLE_POLICY` | **PARTIAL** | Fail-closed ; absence durable de Chainlink ou phase incompatible sans résolution bornée. |
| `REGISTRY_BYPASS_RESISTANCE` | **PARTIAL** | Sur fork, transfert exclusif et guardian lock ; Registry réellement déployé inchangé. |
| `LEGACY_POSITION_COMPATIBILITY` | **PARTIAL** | Série 2030 isolée de la nouvelle politique, fonds/short OI conservés ; son futur règlement reste à définir. |
| `SHARED_VAULT_SAFETY` | **PARTIAL** | Aucune écriture Vault V9 ; couverture V8 représentative, non exhaustive. |
| `FORK_TESTS` | **PASS ciblé** | 5 tests fork V9, dont deux preuves réelles concordantes et un litige Pyth réel avec référence synthétique ; pas de transaction publique. |
| `GAS_AND_COST` | **PARTIAL** | Gas local mesuré ; frais futurs Pyth, gouvernance et accès aux payloads inconnus. |
| `PROPOSED_ECONOMIC_PARAMETERS` | **PARTIAL** | Valeurs et conséquences ci-dessus ; non approuvées. |
| `REMAINING_BLOCKERS` | **BLOCKED** | Accord économique, règlement des séries historiques, disponibilité des preuves à l'échéance, séquenceur Base Sepolia, récupérabilité et couverture complète du Vault. |
| `GIT_STATUS` | **PASS après commit local** | Aucun push ni déploiement. |
| `NEXT_ACTION` | **GO pour soumettre la politique prospective à approbation** | Approbation distincte de la règle de priorité et des paramètres ; aucune action on-chain. |

**Recommandation unique : GO pour soumettre cette politique de règlement des nouvelles séries Call à l'approbation opérateur.** Cette décision ne vaut ni autorisation de déploiement ni feu vert économique. La série historique 2030, l'indisponibilité durable des sources et les chemins non qualifiés du Vault restent bloqués avant toute bascule réelle.
