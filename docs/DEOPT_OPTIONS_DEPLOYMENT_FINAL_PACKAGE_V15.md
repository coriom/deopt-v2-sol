# DEOPT_OPTIONS_DEPLOYMENT_FINAL_PACKAGE_V15

État : paquet local de préparation, **aucune transaction Base Sepolia émise**. Les valeurs économiques de la première ETH Call ci-dessous sont des propositions. La politique de règlement n'est approuvée que pour la bêta fermée testnet.

## Déploiement

`script/DeployOptionsIsolatedV14.s.sol` produit neuf transactions CREATE consécutives. L'estimation provient d'une simulation Foundry Base Sepolia sans `--broadcast`, à partir du commit Solidity `2f33e888dc5876652d5c7aa79c1706b3ece4f980`. La limite par transaction à retenir est 16 777 216 gas. La limite de bloc lue au bloc 55 204 686 est 120 000 000 gas ; elle ne remplace pas cette limite individuelle.

| Nonce conditionnel (base 812) | Contrat | Gas de la transaction simulée |
| ---: | --- | ---: |
| 812 | OracleRouter | 2 124 566 |
| 813 | CollateralVault | 5 029 609 |
| 814 | OptionProductRegistry | 4 847 671 |
| 815 | MarginEngine | 7 329 520 |
| 816 | RiskModule | 5 427 674 |
| 817 | OptionMatchingEngine | 3 255 088 |
| 818 | FeesManagerV2 | 2 557 553 |
| 819 | InsuranceFund | 2 946 994 |
| 820 | VerifiedOptionSettlementOwner | 6 118 695 |

Somme des limites simulées : **39 637 370 gas** ; maximum individuel : **7 329 520 gas**. Ces neuf créations doivent être diffusées **séparément**, dans cet ordre. L'écart avec la limite laisse de la marge pour chaque CREATE, mais le coût final et les frais réseau restent à vérifier au préflight. Le runtime le plus grand est MarginEngine à 24 463 octets, soit 113 octets sous EIP-170. Les bibliothèques préexistantes `MarginEngineLiquidationLib` (`0xb72a7bc82747ce2a0e11df1307b8cb7ef085cc18`) et `MarginEngineSeizureLib` (`0xeb7530cf6f51930681545f90a18817cf8ff55b2c`) doivent garder leur bytecode vérifié avant toute diffusion.

Adresses prédites **uniquement si le déployeur reste `0xc35f7a8a103a9a4464adfaa76b9b514093d23c27` et que son nonce pending est 812** : OracleRouter `0xcb7bc539ed4A5771F3420f498002e0fc4eE1bD27`, Vault `0x2C4589c88323009db372B4067702e6292ddD294C`, Registry `0x63DE63912BB6743F72ea77847572503Cc93B7d80`, MarginEngine `0xDbbfcE4b1fe6d78dE94084499A871b2BE62E2474`, RiskModule `0x1a8Dc1E8C287199aB7E30241F4556cFCe78f386b`, MatchingEngine `0x81012092ecbB082F928C9D047280eC491f298A16`, FeesManagerV2 `0xc3c813C801621e8aDEBE47bb74FB463c3ecE21A1`, InsuranceFund `0xe92cd4659eA120F7b2A44d7CB6e62755A93ada95`, SettlementOwner `0x064541c40FC80e7A6E9C192c8f401Ef043D191CF`.

Le nonce 812 et les adresses calculées à partir de celui-ci sont **conditionnels**, jamais des adresses définitives. Un nouveau `eth_getTransactionCount(deployer, "pending")` juste avant la première création est obligatoire. Si une autre transaction consomme un nonce, recalculer les neuf adresses, les 36 opérations et tous leurs hashes. Après chaque CREATE, attendre le receipt `status=1`, vérifier l'adresse et le bytecode, puis continuer. Après un échec, conserver les contrats déjà créés et reprendre uniquement avec une nouvelle simulation des nonces/pointeurs ; ne jamais relancer aveuglément les neuf créations.

## Paquet hors ligne

Après avoir chargé `RPC_URL` dans l'environnement du terminal local de l'opérateur (sans afficher sa valeur), effectuer une nouvelle simulation avec l'alias Foundry `options_v14`, sans `--broadcast`, puis générer :

```bash
OPTIONS_V14_DEPLOY_ALLOWED=true forge script \
  script/DeployOptionsIsolatedV14.s.sol:DeployOptionsIsolatedV14 \
  --rpc-url options_v14 --sender <ADRESSE_PUBLIQUE_DU_DEPLOYEUR>
python3 script/options_v15_offline_package.py \
  --deployer <ADRESSE_PUBLIQUE_DU_DEPLOYEUR> \
  --pending-nonce <NONCE_PENDING_FRAIS> \
  --reference-timestamp <TIMESTAMP_DU_BLOC_FRAIS> \
  --eta <TIMESTAMP_SUPERIEUR_A_24H> \
  > /tmp/deopt-v15-unsigned-package.json
```

Le générateur ne signe et n'envoie rien. Il refuse les ordres CREATE et bytecodes inattendus, un script de déploiement modifié depuis la simulation, un mauvais déployeur/chainId, une transaction dépassant la limite individuelle, une adresse calculée incohérente, ou un ETA antérieur au délai Timelock observé de 86 400 secondes. Il encode les appels `queueTransaction` et `executeTransaction` pour le Timelock réel ; chaque hash doit être revérifié au préflight. Les 36 actions sont classées `inert`, `guardian`, `candidate_risk_unapproved`, `ownership_unapproved`, `series_unapproved`. **Toutes les actions nécessitent une autorisation distincte ; les six actions inert visent uniquement à maintenir la pile fermée.** Un test fork impersonne le Safe uniquement localement et vérifie six opérations inert, avec 178 710 gas de queue et 191 256 gas d'exécution en appels directs. Les autres coûts de configuration et les surcoûts Safe/transaction ne sont pas encore mesurés : **budget gas total incomplet**.

La séquence de gouvernance est : déployer les neuf contrats initialement inertes ; vérifier bytecodes et pointeurs ; soumettre séparément les actions inert au Safe/Timelock après autorisation ; attendre le délai effectif ; les exécuter et constater les pauses ; préparer ensuite les permissions guardian, le risque, le transfert du nouveau Registry au vérificateur et la création de série, avec **autorisations distinctes**. Ne pas financer le nouveau Vault ni activer le feed, le matching, la création ou le règlement au stade du déploiement. L'ancien Registry, le Vault historique et leurs sept shorts restent hors du paquet.

## Identité des séries et intégration

La migration backend `0074_option_registry_identity.sql` ajoute `onchain_chain_id` et `onchain_registry_address` à `option_series`, plus unicité sur `(chainId, registry, optionId)` ; elle laisse les lignes historiques sans provenance inférée. Le backend calcule une clé `bytes32 = keccak256(abi.encode(chainId, registry, optionId))`, tout en conservant l'ID brut pour le contrat. La lecture d'une position rejette une provenance Registry incohérente et refuse un ID brut ambigu entre deux Registry. Le frontend expose la provenance dans le type API.

**Cette intégration est partielle.** L'indexeur et le curseur de confirmation restent liés à un seul MarginEngine ; les routes d'ordres, positions, frais et historiques ne prennent pas encore une identité composite de bout en bout. Le catalogue et le formulaire ne permettent pas encore de choisir explicitement entre deux Registry. Aucun endpoint économique hébergé ne doit être ouvert avant une réconciliation dual-Registry complète. La migration a été testée sur PostgreSQL 16 jetable, pas sur une copie de la base de production ; aucune migration n'a été appliquée sur Netcup.

Régression V15 à lancer depuis le dépôt backend : `OPTIONS_V4_CHAIN_ID=84532 OPTIONS_V4_BROWSER=1 OPTIONS_V5_PRODUCT=1 OPTIONS_V13_VERIFIED_SETTLEMENT=1 OPTIONS_V14_ROUTER=1 bash scripts/run-options-anvil-indexer-v4.sh`. Le passage local V15 a obtenu `test result: ok. 1 passed`, la transaction Anvil `0xd073914c19806fa184cfb9f55deccdf641f447259be1355a210a4c7b01eae345`, 27 événements indexés, `PLAYWRIGHT_LIVE_POSITION=PASS`, `PLAYWRIGHT_SETTLED_POSITION=PASS`, `REAL_REORG_ORPHAN_REMOVAL=PASS`, primes/frais/flux de règlement vérifiés. Ce test utilise le **nouveau Registry seul** avec l'ancien état hors de sa base jetable : il ne prouve pas l'intégration simultanée des deux Registry. Le test fork `testV15SameOptionIdAcrossHistoricalAndDedicatedRegistry` démontre la collision effective d'ID brut et la conservation du Registry historique ; le test PostgreSQL 16 jetable démontre l'unicité du triplet et la préservation des lignes sans provenance.

## ETH Call proposée, non approuvée

Observation en lecture seule au bloc 55 204 686 (timestamp 1 793 962 806) : Chainlink ETH/USD `0x4aDC67696bA383F43DD60A9e78F2C97Fbbfc7cb1`, 8 décimales, **2 236,185042 USD**, âge 513 s ; Pyth Core `0x5f52e4DBEA21f5b23523B6e20d50c29ae0a4EB83`, feed ETH `0xff61491a931112ddf1bd8147cd1b641375f79f5825126d665480874634fd0ace`, **2 235,07477567 USD**, confiance 9,76 bps, âge 58 s. Divergence 4,97 bps. Cette lecture ne garantit ni le prix futur ni la disponibilité d'une preuve historique à l'échéance. BTC est exclu.

| Paramètre | Proposition | Justification / contrainte |
| --- | --- | --- |
| Sous-jacent | mWETH `0x4DeEBc5f537F3b8ba0E3393807B4D699D72bDd02` | ETH uniquement, actif testnet existant |
| Cotation et règlement | mUSDC `0x6eAe407f5640B006faC9965182e238582A3B412E`, 6 décimales | Nouveau Vault dédié |
| Strike | 2 250 USD, `225000000000` en 1e8 | ~0,62 % au-dessus du spot observé ; revalider juste avant création |
| Expiration | 27 novembre 2026 à 12:00 UTC, `1795780800` | Revalider que le délai restant est suffisant |
| Taille du contrat | 1 ETH, `100000000` en 1e8 | Définition de série utilisée par le Registry |
| Ordre min/max | 1 contrat / 1 contrat | Proposition de première transaction fermée |
| OI short total | 1 contrat | `setSeriesShortOpenInterestCap(optionId, 1)` après approbation |
| Exposition par wallet | 1 contrat au maximum sous l'OI global | Un plafonnement long séparé n'est pas démontré on-chain |
| Dépôts Vault | 2 000 mUSDC, `2000000000` unités | `setTokenDepositCap` proposé ; ne borne pas à lui seul toutes les expositions |
| Collatéral short | Quote réel du RiskModule obligatoire avant trade | Paramètres locaux candidats : base MM 10 mUSDC, facteur IM 12 000 bps, chocs spot ±3 000 bps ; marge indicative ~788,45 mUSDC au spot observé, non exécutable |
| Frais maker / taker | 50 / 250 ppm de la prime | Valeurs de tier 0 observées dans le constructeur FeesManagerV2 ; destinataire Timelock ; vérifier le câblage et le receipt |
| Frais de règlement | Aucun montant proposé | Aucun barème distinct établi pour le nouveau vérificateur |
| Oracle / contestation | Chainlink principal, Pyth Core secours, ±1 500 s, divergence 100 bps, confiance Pyth 100 bps, contestation 48 h | Politique expérimentale approuvée pour bêta fermée testnet uniquement ; divergence ou absence de preuve = règlement différé |
| Pauses / liquidations | Déploiement inert, guardian Safe ; liquidation selon les contrats Risk/Margin réels | Garder la série inactive jusqu'aux tests et autorisations distinctes |

Le strike, la date, l'OI, le plafond Vault, les paramètres de risque et l'activation économique exigent une décision explicite. Le prix et la prime exécutables proviendront des ordres signés et des vérifications contractuelles, jamais de ce tableau.

## Arrêt et récupération

Arrêter avant toute diffusion si le chainId, le nonce pending, les bibliothèques liées, le bytecode, le Timelock, le Safe, les oracles, les plafonds ou les volumes historiques ne correspondent pas au préflight. Arrêter après tout receipt en échec. Si le déploiement est partiel, laisser la pile inerte et inventorier les adresses créées ; aucun changement au Vault historique n'est requis. Si une preuve oracle manque ou diverge, ne pas finaliser le règlement. Le guardian peut mettre la nouvelle pile en pause ; la reprise du Registry relève du Timelock et d'une autorisation distincte. Aucun rollback automatique ne déplace de fonds ni ne recrée des positions.

Les prochaines étapes sont séparées : (1) approbation de publication Git, (2) approbation de déploiement des contrats, (3) approbation de configuration économique et d'activation, (4) approbation de la première transaction ETH Call contrôlée. Le présent paquet n'accorde aucune de ces autorisations.

Le premier trade testnet, **après** toutes ces approbations, demanderait : une nouvelle lecture de prix et d'état oracle, une quote RiskModule de la marge d'un short, l'approvisionnement de deux wallets jetables en actifs de test, des dépôts limités dans le **nouveau** Vault, la vérification de la série active et du plafond OI, deux intentions EIP-712 avec nonces/échéances distincts, une transaction du vrai MatchingEngine, puis la vérification receipt → événements → indexeur → PostgreSQL → API authentifiée → navigateur. Sur discordance de position ou de flux, mettre la nouvelle pile en pause avant un autre ordre. Le règlement à l'échéance exige une preuve historique admissible et la fin de la fenêtre de contestation ; il ne doit pas être simulé par un prix forcé sur le réseau public.
