# DEOPT_OPTIONS_RELEASE_SAFETY_V12

Date : 2026-11-06. Périmètre : code local et fork Base Sepolia **sans transaction publique**. Ce document ne vaut ni approbation économique ni autorisation de déploiement ou de trading.

## Décision d'architecture

**Séparer les nouvelles Calls du Registry et du Vault historiques.** Déployer une nouvelle pile Options dédiée (Registry, CollateralVault, MarginEngine, RiskModule, OptionMatchingEngine, vérificateur de règlement), avec les mêmes oracles seulement si leur configuration est approuvée. Garder le Registry historique sous son propriétaire Timelock actuel, et ne changer ni les pointeurs de l'ancien Engine ni le Vault partagé. Ne pas installer le `OptionWithdrawalRiskGate` V7 sur le Vault historique dans le paquet de la nouvelle série : cette opération toucherait aussi les utilisateurs Perps et les sept shorts historiques. Le garde reste une correction candidate distincte pour les retraits historiques.

La séparation évite le transfert à sens unique de propriété du Registry historique dans la proposition V11. Elle ne rend pas le nouveau Registry automatiquement récupérable : le vérificateur V11 est immuable et n'expose aucun remplacement du propriétaire. **Ne pas déposer de collatéral dans la nouvelle pile avant d'avoir qualifié un mécanisme de reprise qui conserve la vérification contractuelle des prix, ou avant une acceptation explicite et limitée de ce risque de disponibilité pour la bêta.** Un simple retour du propriétaire au Safe/Timelock réintroduirait la fixation arbitraire des prix et n'est donc pas un rollback sûr après ouverture de positions.

## Matrice des mouvements du Vault historique

| Chemin | Autorité effective | Contrôle et invariant | Preuve V12 / limite |
| --- | --- | --- | --- |
| `deposit`, `depositFor` | Wallet, ou moteur autorisé pour `depositFor` | Crédit égal aux tokens réellement reçus ; total agrégé augmente du montant reçu. | Code `CollateralVaultActions`; pas de nouveau dépôt simulé sur fork. |
| `withdraw`, `withdrawFor`, `transferFromInternalAccount` | Wallet ou moteur autorisé | Passe par `_withdrawInternal` et `getWithdrawableAmount`; une sortie doit diminuer solde interne, total et actifs du même montant. | Fork : oracle invalide bloque les sorties du short, et le long peut retirer 1 unité dans sa marge. `transferFromInternalAccount` bloqué également. |
| `transferBetweenAccounts` | Moteurs autorisés, y compris moteur Perps et InsuranceFund si autorisés | Déplace seulement des écritures internes ; total et token détenu par Vault ne changent pas. La décision de solvabilité appartient au moteur appelant. | Fork : appel utilisateur refusé ; appel avec identité du moteur Options accepté même avec oracle invalide, **uniquement par impersonation du moteur dans le test**. Cette capacité n'établit pas une exploitation par un utilisateur, mais prouve que l'adaptateur de retrait ne couvre pas ce chemin. |
| Primes, frais, funding, liquidations, indemnités | Moteurs Options/Perps, InsuranceFund selon leurs rôles | Utilisent les transferts internes ; conservation des actifs du Vault, obligations de solvabilité propres à chaque moteur. | Appels source identifiés dans `MarginEngineTrading`, `MarginEngineOps`, `MarginEngineLiquidationLib`, `PerpEngineTrading`, `PerpEngineLiquidationLib`, `InsuranceFund`. Qualification exhaustive des conditions d'appel non obtenue. |
| Pauses | Guardian/owner du Vault | `pauseWithdrawals` interdit les sorties ; `pauseInternalTransfers` interdit les mouvements entre comptes. | Fork : les trois voies de sortie/mouvement testées échouent, soldes internes, total et actifs inchangés. |

Le test fork épinglé au bloc **55 041 332** vérifie les soldes du Vault, le total déposé et les sept shorts historiques avant/après les essais. Il ne prouve pas l'absence de toute voie d'exploitation dans chacun des moteurs autorisés ni la santé actuelle au dernier bloc. Le garde de retrait V7 reste une protection partielle du Vault partagé, pas un contrôle universel de ses transferts internes.

## Règlement et risque de disponibilité

Hypothèses V11 conservées, **non approuvées** : Chainlink historique principal ; Pyth Core signé en repli sous condition de borne Chainlink périmée ; fenêtres avant/après de 1 500 s ; divergence strictement supérieure à 100 bps ; confiance Pyth au plus 100 bps ; contestation de 48 h. Deux preuves admissibles divergentes mettent la série en `CHALLENGED`. `resolve` refuse ensuite la finalisation, sans nouveau délai ni prix administrateur. La contestation n'est pas répétable et le prix finalisé est unique. Les tests unitaires et fork ciblés passent ; sur fork, le payload Pyth est authentique mais la borne Chainlink divergente est synthétique. Aucune divergence historique réelle des deux sources à la même échéance n'est ainsi prouvée.

Cette règle protège contre la sélection opportuniste d'un prix au coût d'un **blocage potentiellement indéfini** des obligations et du collatéral. La priorité Chainlink/Pyth et le traitement d'une absence prolongée de preuve requièrent l'approbation économique de l'opérateur. Une récupération par prix libre du Safe/Timelock contournerait la politique. Sans preuve admissible ou règle supplémentaire approuvée et vérifiable, maintenir le règlement en attente.

## Preuves exécutées pendant V12

- `forge test --match-path test/fork/OptionWithdrawalRiskGateFork.t.sol --threads 2` avec `RPC_URL` Base Sepolia local : **9/9 PASS** au bloc 55 041 332. Deux tests montrent le blocage de sortie externe et la frontière des transferts internes ; un test couvre les deux pauses. Le fork a été alimenté par le RPC local, sans émission publique.
- `forge test --match-path test/fork/VerifiedOptionSettlementOwnerFork.t.sol --threads 2` : **7/7 PASS** sur les blocs épinglés V11. Le nouveau test instancie Registry, Vault, Engine, RiskModule et matching dédiés ; le propriétaire du Registry historique, les pointeurs historiques, les sept shorts, le solde et le total du Vault historique restent inchangés. Il prouve la séparation structurelle, **pas** le fonctionnement d'une nouvelle pile configurée ni une transaction Options sur cette pile.
- `forge test --match-path test/unit/settlement/VerifiedOptionSettlementOwner.t.sol --threads 2` : **7/7 PASS** ; prix direct et appel admin interdits, contestation non répétable, finalisation unique.
- `forge fmt --check` sur les deux fichiers fork : **PASS**. `forge build --threads 2` a été lancé puis arrêté après la compilation de 129 fichiers engagée sous forte charge WSL (load 32, swap 1,6 Gio) ; **aucun PASS de build global n'est revendiqué**. Les deux tests fork ont compilé leurs fichiers modifiés avant de passer.
- Aucun composant de production n'a changé. Le banc Options navigateur V6 n'a pas été rejoué : les modifications V12 portent sur les tests fork et le choix d'architecture, pas sur les handlers ou le parcours produit.

## Paquet de release restant à qualifier

1. Approuver distinctement la pile dédiée et les paramètres économiques ci-dessus, y compris la possibilité d'un règlement immobilisé. Ne pas confondre cette décision avec publication Git ou opération Safe.
2. Construire et tester la **récupération du nouveau Registry** sans chemin de prix arbitraire, puis configurer sur Anvil/fork le nouveau Vault, Registry, Engine, RiskModule, matching, vérificateur, token, oracles, fees et InsuranceFund. Vérifier que les permissions des nouveaux moteurs ne s'étendent jamais au Vault historique ; tester Call long/short, liquidations, pause, règlement et tous les flux de collatéral. La preuve structurelle V12 ne remplace pas ce test économique.
3. Préparer les calldatas et autorisations Safe/Timelock exactes seulement après ces tests et après un nouveau préflight RPC. Déployer une série Call **inactive**, comparer bytecode, propriétaires, oracle et pointeurs, puis autoriser séparément l'activation et un premier trade testnet contrôlé. Préserver les sept shorts et tous les soldes historiques.
4. Adapter l'indexeur Rust et le catalogue frontend à deux Registries avec IDs qualifiés par adresse de Registry ; vérifier isolation wallet, réconciliation canonique, fees et rollback. Conserver `OPTIONS_ENABLED=false` et les broadcasters désactivés sur Netcup jusqu'à la validation hébergée distincte.
5. Arrêt : pause du nouveau Registry, du matching et des retraits du nouveau Vault selon l'incident ; ne jamais restaurer ou migrer automatiquement les fonds historiques. Retour arrière logiciel seulement si les positions actives restent lisibles et réglables selon leur règle contractuelle ; sinon préserver l'état et arrêter les nouvelles écritures.

## Verdicts

| Champ | Verdict | Limite déterminante |
| --- | --- | --- |
| `SHARED_VAULT_SAFETY` | **PARTIAL** | Fork représentatif ; moteur autorisé peut transférer des comptes sans le garde de retrait. Nouvelle pile dédiée recommandée. |
| `COLLATERAL_INVARIANTS` | **PARTIAL** | Invariants de conservation testés sur sorties et transferts ciblés ; liquidations/Perps exhaustifs non couverts. |
| `LEGACY_POSITIONS_PRESERVATION` | **PASS sur fork ciblé** | 7 shorts et actifs historiques inchangés pendant la séparation simulée. |
| `REGISTRY_RECOVERY` | **BLOCKED** | Registry historique laissé au Timelock ; remplacement sûr du propriétaire du nouveau Registry non implémenté. |
| `SETTLEMENT_POLICY` | **PARTIAL** | Protection contractuelle locale, paramètres et risque de gel non approuvés. |
| `ORACLE_DIVERGENCE_RESOLUTION` | **PASS fail-closed local / PARTIAL économique** | Divergence bloque la finalisation ; indisponibilité non bornée. |
| `FORK_SECURITY_TESTS` | **PASS ciblé** | 9 garde + 7 vérificateur ; les moteurs de la nouvelle pile ne sont pas entièrement configurés. |
| `OPTIONS_E2E_REGRESSION` | **PARTIAL** | Non rejouée car aucun chemin produit modifié ; nouvelle pile nécessitera un E2E complet. |
| `BASE_SEPOLIA_RELEASE_READINESS` | **BLOCKED** | Reprise du nouveau Registry, tests économiques de la nouvelle pile et approbation des paramètres restent nécessaires. |

**Prochaine opération :** implémenter et simuler la reprise à prix vérifié sur un Registry dédié, puis exécuter le parcours Options local sur cette pile isolée. Aucune transaction Base Sepolia, modification du Vault historique, signature Safe, activation économique, mise en production ou publication Git n'est incluse ici.
