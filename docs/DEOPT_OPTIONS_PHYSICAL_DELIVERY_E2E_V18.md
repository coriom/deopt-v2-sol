# DEOPT_OPTIONS_PHYSICAL_DELIVERY_E2E_V18

7 novembre 2026. Preuves locales uniquement, chainId Anvil 84532. Aucun changement Base Sepolia, Netcup ou Vercel.

## Résultats

| Contrôle | Verdict | Preuve et limite |
| --- | --- | --- |
| PHYSICAL_CALL_LIFECYCLE | PARTIAL | Le moteur local couvre ouverture, exercice européen et déchéance. Le produit hébergé n'utilise pas ce moteur. |
| COVERED_COLLATERAL | PASS local | 2 mWETH verrouillés pour 2 Calls ; delta ERC-20 exact ; transfert taxé refusé ; `forge test --match-path test/unit/options/CoveredCallMarginEngineV17.t.sol -vv` : 12 tests réussis après le dernier ajout. Le contrat expérimental conserve les mWETH dans son propre escrow, séparé du Vault historique. |
| EXERCISE_WINDOW_AND_EXPIRY | PASS local | Fenêtre immuable et bornée, 48 h comme valeur **candidate non approuvée** ; exercice refusé avant expiration et à la limite ; restitution refusée avant limite. Le droit de l'acheteur non présent s'éteint à la limite. |
| ATOMIC_DELIVERY | PASS local | Receipt Anvil `0x2c74b82885fbeecd9726d94fccd91c9a98422c80f844c18840991b4f49436516` : paiement exact de 2 250 mUSDC et livraison de 1 mWETH. Paiement insuffisant et double exercice rejetés en Foundry. |
| NON_EXERCISE_RELEASE | PASS local | Receipt Anvil `0xd90e0b1fc4089bfe87efe79fb665fd40ea2596ae23cedc10976e4a0ac2a3d98b` : restitution de 1 mWETH au vendeur après 48 h ; escrow final nul. |
| MULTIFILL_ACCOUNTING | PARTIAL | Deux fills **cash legacy** dans un même receipt `0x4d733b94319986adaae4a7f4517a26d28cf8458baf4e630a59edd7331491d6cb` sont partitionnés par `log_index` ; trois fills legacy au total donnent 300 000 000 unités natives de prime et 15 000 unités natives de frais acheteur dans Chromium. Le cas physique multi-receipt/multi-fill n'est pas encore intégré au portefeuille. |
| BACKEND_INDEXATION | PARTIAL | Rust décode `CoveredFill`, `PhysicalExercise`, `LongWaived`, `LongExpired`, avec `chain_id`, émetteur, tx/block hash et log index. Le lecteur de positions authentifié reste adapté au MarginEngine cash. |
| POSTGRES_PERSISTENCE | PASS local | `bash scripts/run-options-covered-anvil-v18.sh` : 1 test Rust/PostgreSQL 16 réussi ; les trois receipts physiques réels sont persistés, puis le rejeu n'ajoute aucun événement. |
| FRONTEND_PHYSICAL_EXERCISE | BLOCKED | Aucun bouton produit n'envoie encore l'approbation mUSDC puis `exercise` par un wallet EIP-1193 réel. Le frontend cash n'est pas présenté comme physique. |
| PLAYWRIGHT_FULL_E2E | BLOCKED | Le banc Chromium cash dual Registry passe ; il ne déclenche pas le moteur physique. Aucun FULL_E2E_PASS physique. |
| REORG_RECOVERY | PARTIAL | Après `evm_revert`, les receipts d'exercice et de restitution orphelins disparaissent de PostgreSQL ; le fill antérieur reste canonique. Lecture Rust `openLots(buyer,seller)=2` égale projection des événements. La vue produit physique n'est pas encore disponible. |
| LEGACY_VAULT_ISOLATION | PARTIAL | Le banc cash dual Registry confirme que le Vault legacy reste inchangé pendant un trade dédié. Le banc physique utilise un escrow distinct ; la coexistence physique + Vault legacy dans **un même** scénario reste à prouver. |
| FIRST_CALL_PARAMETERS | BLOCKED | Les valeurs locales 1 ETH, strike 2 250 mUSDC, prime 100 mUSDC et fenêtre de 48 h sont des fixtures, pas une politique approuvée. Frais, limites d'exposition et traitement du non-exercice exigent une décision économique. |
| BASE_SEPOLIA_READINESS | BLOCKED | Aucun déploiement ou trade public autorisé ; intégration physique navigateur, frais, identité du Registry et essai de migration 0074 sur données réelles restent ouverts. |

## Reproduction et portée

Depuis le dépôt Solidity :

```bash
forge test --match-path test/unit/options/CoveredCallMarginEngineV17.t.sol -vv
```

Depuis le dépôt backend, avec Docker local, Anvil, Foundry et PostgreSQL 16 :

```bash
bash scripts/run-options-covered-anvil-v18.sh
OPTIONS_V16_DUAL_REGISTRY=1 OPTIONS_V4_CHAIN_ID=84532 OPTIONS_V4_BROWSER=1 OPTIONS_V5_PRODUCT=1 OPTIONS_V13_VERIFIED_SETTLEMENT=1 OPTIONS_V14_ROUTER=1 CARGO_BUILD_JOBS=1 bash scripts/run-options-anvil-indexer-v4.sh
```

Le premier lanceur vérifie une signature EIP-712 réelle dans le script Foundry, un trade et deux opérations de livraison sur Anvil, les montants ERC-20, l'indexation Rust/PostgreSQL et la correction d'une reorg. Le second vérifie le produit cash existant et la régression des deux Registry. Les clés et jetons du banc sont jetables. Les contrats historiques et les services hébergés ne sont pas modifiés.

## Travail restant avant le premier trade physique Base Sepolia

1. Déclarer le mode de règlement physique pour une série liée au nouveau Registry et router le formulaire existant vers le matcher couvert, sans activer les soumissions hébergées.
2. Exposer les lots `buyer/seller` seulement après lecture `openLots` canonique et rapprochement des événements PostgreSQL, avec une session du wallet propriétaire ; distinguer ces lots des positions cash historiques.
3. Préparer l'approbation mUSDC et l'exercice via le wallet navigateur, puis réindexer et afficher livraison, strike et restitution. Le faux `eth_sendTransaction` de la fixture Playwright existante doit être remplacé par une diffusion **locale Anvil réelle** pour ce scénario.
4. Définir et approuver les frais physiques, la fenêtre et les plafonds ; intégrer leurs transferts réels avant toute affirmation de comptabilité complète.
5. Rejouer dans un même banc les deux Registry avec le moteur physique, un Vault legacy inchangé, plusieurs fills et les deux issues exercice/déchéance. Tester la migration 0074 sur copie des données réelles quand elle est accessible.

**Verdict : NO-GO pour une release économique.** Le prochain jalon concret est le raccordement du formulaire, du lecteur authentifié de lots et du wallet d'exercice au moteur physique dans le banc local dual Registry.
