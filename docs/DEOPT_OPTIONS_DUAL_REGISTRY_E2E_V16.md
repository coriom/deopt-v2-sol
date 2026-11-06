# DEOPT_OPTIONS_DUAL_REGISTRY_E2E_V16

État : validation locale uniquement. Aucun push, déploiement, signature Safe ou transaction Base Sepolia. Le rapport V15 reste le manifeste des neuf contrats et des 36 opérations préparées. Ses adresses issues du nonce 812 sont indicatives : relire le nonce `pending`, les bytecodes, les bibliothèques et les oracles avant toute autorisation de diffusion.

## Reproduction

Depuis `deopt-v2-backend`, avec Docker, Foundry, Node/Playwright et les artefacts Rust locaux :

```bash
OPTIONS_V16_DUAL_REGISTRY=1 OPTIONS_V4_CHAIN_ID=84532 \
OPTIONS_V4_BROWSER=1 OPTIONS_V5_PRODUCT=1 \
OPTIONS_V13_VERIFIED_SETTLEMENT=1 OPTIONS_V14_ROUTER=1 \
CARGO_BUILD_JOBS=1 bash scripts/run-options-anvil-indexer-v4.sh
```

Le lanceur crée Anvil et PostgreSQL 16 jetables sur loopback, utilise deux wallets de développement Anvil, et les arrête à la sortie. Il déploie deux piles locales distinctes avec le **même identifiant brut** de série. La pile de référence possède un Registry, un Vault, un moteur et des frais propres ; une position Call long/short y est réellement exécutée avant le parcours produit. La pile dédiée dispose de son Registry récupérable, de son Vault, du vérificateur de règlement et du routeur oracle local. Les prix de ce banc sont déterministes et ne prouvent pas la disponibilité des feeds Base Sepolia.

Le navigateur sélectionne explicitement la série dédiée, authentifie deux wallets, signe l'intention EIP-712, passe par les handlers Rust de simulation et de diffusion locaux, puis vérifie les positions. L'indexeur suit les deux moteurs, les deux Vaults et les deux gestionnaires de frais. Les lectures de position utilisent `(chainId, registryAddress, optionId)` ; les receipts de prime, frais et règlement exigent le Vault et l'émetteur exacts. La migration 0074 laisse les lignes historiques sans provenance et refuse les identifiants de série non canoniques. La lecture reste `partial` pour les montants non prouvés, dont le collatéral par position et les agrégations multi-fills. Les routes d'historique et d'ordres non qualifiées restent fermées en mode double Registry.

Le test retourne le statut de la vraie transaction Anvil, le hash du bloc, les événements persistés, les soldes des Vaults avant/après, puis le règlement prouvé par des rounds locaux. Il vérifie ensuite une réorganisation Anvil : l'événement orphelin et sa position dédiée disparaissent, tandis que la position du Registry de référence survit. La signature d'un Registry ne doit jamais être réutilisable sur l'autre ; le domaine EIP-712 est celui du MatchingEngine respectif.

Exécution V16 du 6 novembre 2026 : `test result: ok. 1 passed`, `V16_SAME_RAW_OPTION_ID_TWO_REGISTRIES=PASS`, `V16_CROSS_REGISTRY_EIP712_REPLAY=REJECTED`, `V15_WATCHER=BROADCAST_OK`, transaction Anvil `0xb7b1275ae6fade77c74080c32f9c782ac30172772e0eefbe3b13810b4a8024ae`, `RUST_PG_INDEXED_EVENTS=54`, `PLAYWRIGHT_LIVE_POSITION=PASS`, `PLAYWRIGHT_SETTLED_POSITION=PASS`, `REAL_REORG_ORPHAN_REMOVAL=PASS`. Le contrôle `V16_LEGACY_VAULT_UNCHANGED_BY_DEDICATED_TRADE=PASS` compare les soldes avant/après ; les preuves de prime (`100000000` unités natives) et de frais acheteur/vendeur (`25000`/`5000`) sont liées aux transferts du nouveau Vault. Les refus oracle invalide, oracle périmé, collatéral insuffisant et ordre expiré passent dans la même exécution. Le premier trade de référence et le trade dédié sont deux fills sur des Registry différents ; **les agrégations de plusieurs fills sur une même série restent à développer**.

## Plafonds expérimentaux de la première Call

Le banc V16 applique au **nouveau Vault uniquement** le candidat `setTokenDepositCap(mUSDC, 2_000_000_000)` et à la série dédiée `setSeriesShortOpenInterestCap(optionId, 1)`. Il relit les plafonds on-chain, refuse un dépôt au-delà de la limite, et le test unitaire MarginEngine vérifie le refus d'un second short au-delà de l'OI. Ces réglages locaux ne sont pas une approbation économique. La limite de dépôt est agrégée par token, sans plafonnement par wallet ; le plafond OI borne les shorts, pas le payoff d'une Call. Le contrat impose `contractSize1e8 == 1e8` : réduire la taille à 0,01 ETH n'est pas une simple configuration. À 4 500 USD pour un strike 2 250 USD, le payoff d'une Call 1 ETH serait 2 250 mUSDC, au-dessus d'un Vault plafonné à 2 000 mUSDC si aucune autre source de solvabilité n'est démontrée. Les chocs, liquidations et le financement de l'InsuranceFund doivent être qualifiés avant toute activation économique. Ne pas traiter la marge indicative de 788,45 mUSDC comme une garantie de paiement.

## Portes restantes

1. Migration 0074 sur restauration isolée réelle de la base de production, si accessible sans transfert de clé privée ; le test PostgreSQL jetable ne remplace pas cette preuve.
2. Comptabilité multi-fills, collatéral par position, historiques et frais agrégés avec provenance du Vault. Une quantité on-chain correcte ne suffit pas à attribuer un montant économique.
3. Revalidation des feeds ETH, du prix, du nonce pending, des limites gas et des 36 actions du paquet V15 au préflight frais. BTC reste exclu.
4. Approbations séparées pour publication Git, déploiement inert des neuf contrats, configuration/activation économique, puis première transaction testnet contrôlée.

La politique de règlement Chainlink principal, Pyth Core secours, fenêtres 1 500 s, divergence 100 bps, confiance Pyth 100 bps et contestation 48 h n'est approuvée que pour la bêta fermée testnet. Si les preuves manquent ou divergent, le règlement reste différé ; le collatéral peut rester immobilisé.
