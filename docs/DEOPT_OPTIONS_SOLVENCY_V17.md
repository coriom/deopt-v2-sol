# DEOPT_OPTIONS_SOLVENCY_V17

État : développement local. Aucune activation économique ni transaction Base Sepolia.

## Déficit démontré

`forge test --match-path test/unit/margin/MarginEngine.t.sol --match-test testV17ShortOiCapDoesNotCoverExtremeCallPayoff -vv` passe. Sur le contrat réel local, un short Call de taille 1 ETH, strike 2 000 USD, OI plafonné à 1, dispose de 1 000 mUSDC puis reçoit 100 mUSDC de prime. Au règlement à 4 500 USD, le payoff est 2 500 mUSDC et `seriesBadDebt` augmente de 1 400 mUSDC. Le test utilise un oracle local et des actifs de test. Il démontre que le plafond OI ne garantit pas la solvabilité.

La proposition V15 (strike 2 250 USD, taille fixe 1 ETH, Vault plafonné à 2 000 mUSDC) est rejetée pour toute activation. Le plafond de dépôt est agrégé, ne verrouille pas une réserve par short et ne borne pas le payoff. Le code actuel calcule le payoff cash d'après le prix de règlement et permet de comptabiliser la dette non couverte. Aucun paramètre fini de mUSDC ne garantit à lui seul une Call classique à hausse non bornée.

## Modèles étudiés

| Modèle | Conservation des droits | Contrats requis | Décision |
| --- | --- | --- | --- |
| Call couverte par 1 mWETH verrouillé par short, exercice physique au strike | Conserve l'exposition classique à la hausse, mais remplace le règlement cash par livraison physique | Nouveau moteur/règlement et escrow mWETH, paiement du strike par l'acheteur, verrou non contournable, traitement des expirations et défauts | Architecture retenue par l'opérateur pour développement local ; activation économique non autorisée. |
| Call cash plafonnée, réserve mUSDC intégrale par short | Borne la responsabilité, mais modifie le payoff au-delà du plafond | Plafond contractuel de payoff, réserve ségréguée par short, contrôle sur chaque fill et chaque sortie, restitution après clôture/règlement, preuve de conservation | Chemin technique plus court, soumis à approbation explicite du payoff plafonné et du montant. |
| Modèle actuel mUSDC + OI 1 + cap 2 000 | Payoff cash classique inchangé | Aucun | NO-GO : déficit reproductible. |

Le Vault actuel peut recevoir mWETH, mais le moteur de règlement Options de cette pile transfère la devise de règlement mUSDC. Déposer mWETH dans le Vault ne transforme donc pas le short en Call couverte. Une liquidation dépend d'un oracle disponible et d'une exécution avant le mouvement ; elle ne constitue pas une couverture contractuelle garantie à l'échéance. La panne oracle doit empêcher les nouvelles augmentations de risque ; les actifs verrouillés doivent rester non retirable tant que l'obligation existe.

## Prototype de livraison physique V17

L'opérateur a choisi la Call couverte en mWETH. `src/experimental/CoveredCallMarginEngine.sol` est une **expérience locale**, distincte du `MarginEngine` cash et du Vault historique. Elle verrouille un mWETH par short dans le contrat, exige que le matcher EIP-712 soit figé sur le bon Registry et le bon moteur, perçoit la prime en mUSDC, et livre le mWETH contre le strike en mUSDC après l'échéance. Un solde mUSDC fini n'est plus supposé couvrir la hausse illimitée de l'ETH. Le nouvel appariement est impossible sans oracle frais ; la livraison physique reste possible en panne oracle, car l'échange au strike ne dépend pas du spot. Le vendeur n'a aucun retrait unilatéral du mWETH immobilisé. L'acheteur seul peut renoncer au droit d'exercice après échéance ; sans exercice ni renonciation, la couverture reste bloquée. Aucun délai de déchéance unilatérale n'a été choisi.

Commande : `forge test --match-path test/unit/options/CoveredCallMarginEngineV17.t.sol -vv`. Résultat : 8/8 PASS. Les tests utilisent le vrai `OptionMatchingEngine`, des signatures EIP-712 EOA, un oracle local, et des ERC-20 de test. Deux fills verrouillent 2 mWETH ; même à 100 000 USD de spot, l'exercice transfère 4 500 mUSDC de strike au vendeur et 2 mWETH à l'acheteur, sans dette cash supplémentaire. Les tests refusent un quatrième short sans mWETH, l'ouverture sans oracle valide, un retrait non autorisé, le changement de moteur/Registry du matcher figé, une seconde exécution, et montrent que la pause ou la panne oracle ne bloque pas l'exercice d'une position préexistante. Un défaut de paiement du strike conserve le lot et le collatéral, puis un exercice peut réussir après réapprovisionnement.

**Limites empêchant le déploiement :** le contrat expérimental ne gère ni frais protocolaires, ni positions transférables, ni fenêtre d'exercice/lapse gouvernée, ni fermeture anticipée, ni liquidation, ni indexation PostgreSQL, ni gestion de reorg, ni affichage navigateur du règlement physique. Les routes Rust et le formulaire actuel parlent encore du moteur cash ; les 7 tests ci-dessus ne sont donc pas une preuve de parcours produit couvert. L'identité du lot reste `(Registry, optionId, buyer, seller)` dans un moteur mono-série. Le prototype impose 18 décimales pour mWETH, 6 pour mUSDC et un strike représentable exactement ; ces hypothèses doivent être vérifiées avec les contrats testnet visés. Aucun mécanisme ne doit rebasculer une série couverte vers le règlement cash. Les paramètres de déchéance, de transfert de position et de frais nécessitent des décisions économiques avant une release. Le produit hébergé reste verrouillé.

## Comptabilité multi-Registry vérifiée localement

Commande : depuis le backend, `OPTIONS_V16_DUAL_REGISTRY=1 OPTIONS_V4_CHAIN_ID=84532 OPTIONS_V4_BROWSER=1 OPTIONS_V5_PRODUCT=1 OPTIONS_V13_VERIFIED_SETTLEMENT=1 OPTIONS_V14_ROUTER=1 CARGO_BUILD_JOBS=1 bash scripts/run-options-anvil-indexer-v4.sh`.

Résultat V17 : `test result: ok. 1 passed`, 75 événements réels indexés, transaction dédiée `0xe662703876f70e6951c06a9565af95f37b111631f7370221a93162b25fbe02b7`, bloc `0x16cdb7ed29552984da17aa917678bfef59a3b50fe89d32bdd469561ce97fd293`. Deux fills legacy successifs ont des nonces et receipts distincts ; l'API exige pour chacun le transfert du Vault et l'événement du FeesManager corrects avant d'agréger 200 000 000 unités natives de prime et 10 000 unités de frais acheteur. Le navigateur affiche les deux preuves avec `2 fills`. Si un receipt contient plusieurs fills ou si la même transaction est indexée en double, le montant n'est pas marqué vérifié sans corrélation au log. Le Vault legacy ne bouge pas lors du trade dédié. Après règlement dédié puis reorg, la position legacy et ses preuves survivent ; la position dédiée orpheline disparaît. Les frais et primes de sens opposés, ou sans receipts complets, restent non vérifiés. Le collatéral n'est toujours pas attribuable canoniquement par position à partir des états et événements disponibles : aucune valeur inventée n'est affichée. Ce banc demeure le produit **cash** V16 ; il ne qualifie pas encore le prototype physique.

## Conditions avant première Call testnet

La livraison physique couverte a été choisie pour le développement local. Avant Base Sepolia, il faut approuver la sémantique d'exercice et de déchéance, les frais et les limites de taille ; câbler la preuve de réserve, les événements et le règlement physique à Rust, PostgreSQL et Next.js ; puis rejouer le banc produit dual Registry avec le nouveau moteur. Exiger des tests de solvabilité sous prix extrêmes, oracle indisponible, retrait abusif, reorg et règlement répété avant tout déploiement. Le Registry et Vault historiques restent intacts.
