# DEOPT_OPTIONS_PHYSICAL_PRODUCT_E2E_V19

7 novembre 2026. Validation locale sur Anvil `84532` avec PostgreSQL 16 jetable, Rust réel, Next.js et Chromium. Aucune transaction Base Sepolia ni modification hébergée.

## Reproduction

Depuis `deopt-v2-backend` :

```bash
OPTIONS_V19_PRODUCT=1 CARGO_BUILD_JOBS=1 bash scripts/run-options-covered-anvil-v18.sh
```

Le lanceur choisit quatre ports loopback libres, installe simultanément un Registry et un Vault cash historiques avec fonds représentatifs, ainsi que le Registry et l'escrow physique dédiés. Il nettoie seulement ses processus et son conteneur PostgreSQL jetables. Dernière exécution : `V19_PHYSICAL_PRODUCT_E2E=PASS`, 1 test Rust et 1 test Playwright réussis. `forge test --match-path test/unit/options/CoveredCallMarginEngineV17.t.sol -q` et `npm run typecheck` ont aussi réussi. La régression V18 (`bash scripts/run-options-covered-anvil-v18.sh` avec ports locaux libres) a vérifié deux fills dans un même receipt et la suppression des événements orphelins après reorg.

## Verdicts

| Contrôle | Verdict | Preuve et limite |
| --- | --- | --- |
| PHYSICAL_LOT_ACCOUNTING | PARTIAL | Rust agrège `CoveredFill`, `PhysicalExercise`, `LongWaived` et `LongExpired` par chaîne, Registry lié au moteur, `optionId`, acheteur et vendeur ; compare le solde ouvert à `openLots`. Le contrat rend les unités fongibles par paire acheteur/vendeur : aucun `lotId` canonique individuel n'existe. Les frais restent `null`. |
| MULTIFILL_RECONCILIATION | PASS | Régression V18 : deux `CoveredFill` distincts dans le même receipt `0x89792f5bf13fa41521e2042968c377626ab4f73d9cfac94123c553aff8ec4225`, séparés par `log_index` et persistés sans doublon. V19 agrège deux unités physiques ouvertes puis une exercée et une déchue. |
| AUTHENTICATED_PHYSICAL_POSITIONS | PASS | Route Rust `GET /options/accounts/:address/physical-positions` : session wallet requise, 401 anonyme et 403 inter-wallet vérifiés dans Chromium. Le lecteur refuse une divergence du hash de curseur ou de `openLots`. |
| FRONTEND_EXERCISE | PASS | Le vrai portefeuille Next.js déclenche l'approbation ERC-20 bornée au strike puis `exercise` via le wallet EIP-1193 automatisé ; aucun backend custodial ne signe cette transaction. L'action est désactivée dans le build de production. |
| WALLET_STRIKE_PAYMENT | PASS | Receipt Anvil d'exercice `0xb18bab8e3c86f10cb581747cf214198a311dc5e5f7411523d12ddc13d52ddeab`, bloc 66 lors de la dernière exécution. Paiement 2 250 000 000 unités natives mUSDC ; solde acheteur final 2 550 000 000, affiché dans Chromium. |
| ATOMIC_WETH_DELIVERY | PASS | Même receipt : 1 000 000 000 000 000 000 unités natives mWETH livrées à l'acheteur ; receipt `success`, événement indexé avec le même hash et solde ERC-20 réel vérifié. |
| SELLER_COLLATERAL_RETURN | PASS | Receipt navigateur `0xa3f033f1c6a77197570d1eda3e859e07f1828e8526ecc35e4c6c3ae63d7fb7e7`, bloc 68 : après la fenêtre de test de 48 h, 1 mWETH est restitué au vendeur et l'escrow tombe à zéro. Solde vendeur 1 mWETH et 2 450 000 000 mUSDC confirmé par contrat et affiché. |
| PHYSICAL_PLAYWRIGHT_E2E | PASS | Formulaire produit, deux signatures EIP-712, handler Rust de simulation et diffusion locale, receipt de trade `0x22450046b8e7c0a2d3f06244a679698c3d91bf42430dcbc3fa5d14fa4cf56607`, indexation PostgreSQL, exercice, restitution, affichage et rechargement Chromium. Le déclencheur du handler de diffusion appartient uniquement au banc local ; aucune route économique publique nouvelle n'est ajoutée. |
| REORG_RECOVERY | PASS | Snapshot/revert Anvil après exercice et restitution ; les receipts orphelins disparaissent des projections, `openLots=2` redevient canonique et le navigateur cesse d'afficher la livraison. Puis l'indexeur est arrêté et relancé depuis son curseur PostgreSQL sans dupliquer le fill (`V19_INDEXER_RESTART_CURSOR=PASS`). |
| LEGACY_ISOLATION | PASS | Deux Registry coexistent pendant le scénario. Le Vault legacy contient un solde avant le trade ; le test compare son solde après et obtient `V19_LEGACY_VAULT_UNCHANGED=PASS`. Le moteur physique conserve ses mWETH dans son propre escrow. |
| ECONOMIC_INVARIANTS | PARTIAL | Le strike, la prime et les transferts mWETH sont vérifiés par receipts, événements, état ERC-20 et soldes. Les tests Foundry refusent sous-couverture, paiement insuffisant, double exercice et restitution prématurée. Aucun FeesManager physique n'est câblé ; aucun montant de frais canonique n'est donc affirmé. |
| ONE_COMMAND_REPRODUCTION | PASS | La commande ci-dessus a été exécutée après sélection automatique des ports et a produit `V19_PHYSICAL_PRODUCT_E2E=PASS`. |
| BASE_SEPOLIA_REMAINING_GATES | BLOCKED | Déploiement de la pile physique non autorisé ; fenêtre de 48 h, strike, prime, frais et plafonds d'exposition non approuvés pour l'ouverture. Tester la migration 0074 sur une copie des données réelles, qualifier les oracles et les permissions du nouveau Registry, puis obtenir des autorisations séparées pour publication Git, déploiement et première transaction testnet. Les Calls cash et leurs fonds historiques restent séparés. |
| GIT_STATUS | PASS local | Modifications V19 limitées aux trois dépôts, à committer localement. Aucun push. |

## Prochaine opération

Faire approuver les paramètres économiques exacts et le périmètre de publication Git du moteur physique. La livraison locale est validée ; la release Base Sepolia et l'ouverture économique restent des décisions distinctes.
