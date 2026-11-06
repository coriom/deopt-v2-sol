# DEOPT_OPTIONS_ISOLATED_STACK_E2E_V13

## Périmètre et preuves

Cette validation concerne uniquement Anvil et un fork Base Sepolia en lecture seule. Aucun contrat, service hébergé, fonds ou état historique n'a été modifié. Les paramètres de règlement restent des **hypothèses non approuvées**.

| Contrôle | Verdict | Preuve et limite |
| --- | --- | --- |
| `NEW_REGISTRY_RECOVERY` | PASS local | Nouveau vérificateur préparé, Registry mis en pause, transfert de propriété en deux étapes et propositions copiées dans une transaction. Les échéances de contestation restent inchangées. 12 tests unitaires, dont des opérations réellement programmées et exécutées par `ProtocolTimelock`. Maximum 64 séries et quatre remplacements successifs. |
| `NEW_VAULT_ISOLATION` | PASS ciblé | Nouvelle pile locale Registry/Vault/Margin/Risk/Matching/Fees/Insurance indépendante. Sur fork épinglé au bloc 55 041 332, le nouveau moteur et le matching ne sont pas autorisés sur le Vault historique ; aucun pointeur du Vault historique n'est modifié. |
| `LEGACY_STATE_PRESERVATION` | PASS sur fork | Propriétaire du Registry historique, moteur du Vault historique, total déposé, actifs du Vault, solde du vendeur et sept shorts historiques identiques avant/après création et récupération de la pile dédiée. Ce test ne qualifie pas tous les usages historiques du Vault. |
| `SETTLEMENT_VERIFICATION` | PASS local et fork ciblé | Le prix direct dans le nouveau Registry est refusé ; la Call locale est réglée après deux rounds Chainlink encadrant l'échéance et 48 h. Les tests fork utilisent les feeds Chainlink et un payload Pyth Core authentique ; la divergence bloque la finalisation. L'E2E local utilise un feed Chainlink **déterministe de test** et un Pyth indisponible. |
| `ECONOMIC_INVARIANTS` | PASS pour la Call testée, PARTIAL général | Transaction Anvil réelle, 27 événements indexés, prime de 100000000 unités natives, frais acheteur 25000 et vendeur 5000, conservation du Vault, retrait excessif rejeté par le vrai RiskModule, soldes et flux de règlement concordants. Pas de preuve exhaustive pour toutes séries, liquidations ou PnL multi-fills. |
| `FULL_OPTIONS_E2E` | PASS local | Formulaire Next.js, deux signatures EIP-712, handler Rust, OptionMatchingEngine, receipt Anvil, indexeur Rust/PostgreSQL, API authentifiée, affichage Playwright, règlement, reorg et reprise. Test intégré : 1 réussi, 0 échoué. |
| `ORACLE_FAILURE_RECOVERY` | PARTIAL | Oracle invalide/périmé et collatéral insuffisant rejetés ; absence de preuve ou contestation contradictoire laisse le règlement en attente. Le collatéral peut rester immobilisé sans limite connue. |
| `GOVERNANCE_PERMISSIONS` | PARTIAL | Guardian peut mettre en pause, seul le Timelock peut préparer/transférer/accepter le remplacement ; test local du délai Timelock. Le Timelock peut techniquement choisir un successeur malveillant qui imite les getters de politique : le hash du bytecode et ses appels doivent être revus avant chaque opération. Il n'existe pas de garantie on-chain contre cette gouvernance malveillante. |
| `BASE_SEPOLIA_DEPLOYMENT_READY` | BLOCKED | Politique économique non approuvée, configuration réelle OracleRouter/RiskModule non qualifiée pour cette pile, adresses et nonces de déploiement non fixés, tests hébergés non réalisés. Le banc local utilise `ScenarioOptionOracle` pour le risque courant. |
| `ECONOMIC_POLICY_DECISIONS` | BLOCKED | À approuver séparément : Chainlink principal, Pyth Core en secours, fenêtres avant/après échéance de 1500 s, divergence et confiance de 100 bps, contestation de 48 h, absence de preuve = règlement différé. Une divergence authentique supérieure à 100 bps bloque la finalisation automatique. |

### Reproduction

Depuis `deopt-v2-sol` :

```bash
forge test --match-path test/unit/settlement/VerifiedOptionSettlementOwner.t.sol --threads 2
# Fork : RPC_URL Base Sepolia fourni localement, jamais dans les sorties.
forge test --match-path test/fork/VerifiedOptionSettlementOwnerFork.t.sol --threads 2
```

Depuis `deopt-v2-backend`, la commande suivante crée et nettoie ses seules ressources de test :

```bash
OPTIONS_V13_VERIFIED_SETTLEMENT=1 OPTIONS_V5_PRODUCT=1 OPTIONS_V4_CHAIN_ID=84532 OPTIONS_V4_BROWSER=1 bash scripts/run-options-anvil-indexer-v4.sh
```

Lors du run V13, la transaction de trading Anvil est `0x05eeba08b0a72ccaa7ca0dba0a6943217ca8ab3ca5a64185409deea96cc2ff72`, dans le bloc `0x672e034c94a903840246aa9ae7205cfed9869f2c23d504547ebb8d10914d7e62`. Il s'agit exclusivement du réseau local Anvil, chainId 84532 ; ces hashes ne décrivent aucune transaction publique. Le test vérifie aussi le refus du rejeu, du prix direct, du double règlement, de l'ordre expiré, de l'oracle invalide/périmé, du collatéral insuffisant et de l'accès inter-wallet. Après snapshot/revert, la position orpheline disparaît du navigateur.

## Paquet de release proposé, non autorisé

1. **Décision économique distincte.** Fixer les valeurs ci-dessus et accepter explicitement le risque de règlement indéfiniment différé quand les preuves manquent ou divergent. Déterminer une procédure de résolution supplémentaire avant tout dépôt utilisateur si ce risque est inacceptable. Aucune valeur administrateur libre ne constitue une solution.
2. **Artefacts et adresses.** Construire les contrats depuis un commit Solidity approuvé, enregistrer leurs hashes de bytecode, vérifier l'absence de secrets, fixer le déployeur et son nonce au moment de la release. Calculer les adresses CREATE avec `cast compute-address --nonce <nonce> <deployer>` pour chaque transaction, puis comparer les receipts. Les adresses Anvil ci-dessus ne prédisent pas celles de Base Sepolia. Le script local estime 41 874 671 gas pour toute sa configuration de test, soit une borne indicative seulement : établir un budget on-chain à partir des transactions de déploiement finales et du gas du réseau avant autorisation.
3. **Déploiement initial séparé.** Nouveau Registry, Vault, MarginEngine, RiskModule, OptionMatchingEngine, FeesManagerV2, InsuranceFund et vérificateur. Réutiliser uniquement les composants externes dont version, feed ID, décimales et permissions auront été vérifiés. N'autoriser aucun nouveau moteur sur le Vault historique ; ne changer ni son propriétaire ni ses pointeurs. Configurer les rôles, approbations, caps, pauses et adresses, puis comparer chaque lien à la matrice du script local.
4. **Gouvernance.** Préparer les opérations Safe/Timelock exactes seulement après revue des adresses et du bytecode. Transférer le nouveau Registry au vérificateur via la procédure en deux étapes, créer la Call **inactive**, vérifier l'état et les obligations, puis demander une autorisation distincte d'activation. La récupération suit `prepareRecovery` → pause guardian → `handoffTo` → `acceptRecoveredOwnership`, chaque opération Timelock étant programmée et vérifiée. Revoir le bytecode du successeur avant la première étape et conserver le Registry en pause pendant la reprise.
5. **Intégration hébergée.** Qualifier l'OracleRouter et les feeds de risque pour la nouvelle pile ; adapter le catalogue et l'indexeur Rust à une identité `(registry, option_id)` et aux nouveaux événements, migrations PostgreSQL sur copie d'abord. Déployer backend et frontend sous flags désactivés, tester HTTPS, authentification, isolation wallet et lectures. Préserver les services économiques désactivés avant un jalon séparé.
6. **Premier trade testnet contrôlé.** Préflight RPC frais : chainId, feed IDs, séquenceur, fraîcheur, propriété, rôles, pauses, actifs et sept shorts historiques. Autoriser séparément l'activation, puis une seule transaction de test avec wallets jetables et montants plafonnés. Comparer receipt, événements, Vault, positions, indexeur et navigateur. Mettre en pause la nouvelle création, le matching et les retraits du nouveau Vault si les invariants divergent ; préserver les fonds et obligations pour le règlement vérifié. Aucun rollback destructif du Vault ou des séries historiques.

**Décision actuelle :** la pile Options Call dédiée fonctionne localement. La release Base Sepolia demeure bloquée par l'approbation économique, la qualification des oracles/permissions réels et une autorisation de déploiement distincte. Aucun push ni déploiement n'est inclus dans V13.
