# DEOPT_OPTIONS_V21_RELEASE_GATE — paquet local, sans autorisation de diffusion

## Politique approuvée, bêta fermée Base Sepolia uniquement

Call européenne physique ETH, un contrat = 1 mWETH (18 décimales). Le vendeur immobilise exactement 1 mWETH dans `CoveredCallMarginEngine` pour chaque short ; l'acheteur paie la prime à l'ouverture. Après l'échéance, l'acheteur peut payer le strike en mUSDC (6 décimales) et recevoir le mWETH dans la même transaction. Il peut renoncer à son droit après l'échéance. Après 48 heures sans exercice, chacun peut restituer le mWETH au vendeur. Aucun token de position ni fonction de transfert de lot n'existe. L'exercice et la restitution ne dépendent pas d'un prix oracle.

- Strike **candidat** : 2 100 mUSDC, à requalifier avec le prix et les conditions du marché avant la création ; il n'est pas figé par l'approbation.
- Échéance **candidate** : 27 novembre 2026 à 12:00 UTC (`1795780800`), à revalider au préflight.
- Fenêtre d'exercice approuvée pour ce test : 48 heures, fixée au constructeur.
- Frais maker, taker et exercice : zéro. `configureFees(address(0),0,0)` avant la liaison du moteur ; la fonction d'exercice n'a pas de prélèvement.
- Maximum short ouvert de cette série : un contrat global et un contrat par wallet. `configureExposureCaps(1,1)` avant `bindMatchingEngine`. Les compteurs diminuent seulement lors de l'exercice, de la renonciation ou de la restitution. La configuration est ensuite figée. Aucune limite de dépôt d'un Vault séparé n'est nécessaire : seul le mWETH d'un fill accepté entre dans l'escrow, et le plafond est de un.
- Le barème 50/250 ppm est un scénario de test seulement. Aucune activation par ce paquet.

## Manifest de la nouvelle pile physique

Trois créations indépendantes :

| Ordre | Contrat | Propriétaire | État initial sûr |
| --- | --- | --- | --- |
| 1 | `OptionProductRegistry` nouveau | ProtocolTimelock `0xa67f8E8E673ce4bb2Fb563B0e6E9FA8F70E3b588` | Aucune série, aucun actif autorisé. |
| 2 | `CoveredCallMarginEngine` | Même Timelock | Pausé, matcher non lié, plafonds non configurés, frais nuls. Tient lui-même le collatéral ; aucun pointeur vers le Vault historique. |
| 3 | `OptionMatchingEngine` | Même Timelock | Le propriétaire est exécuteur par construction, mais le moteur physique reste pausé et non lié. Aucun autre exécuteur n'est autorisé. |

Scripts : `script/DeployOptionsPhysicalV21.s.sol`. Le drapeau `OPTIONS_V21_DEPLOY_ALLOWED` est faux par défaut et chaque script refuse une chaîne différente de 84532. Les adresses de mWETH, mUSDC et Timelock sont vérifiées à l'exécution. Les adresses prédites et nonces devront être recalculés au dernier préflight ; aucun nonce ancien ne doit être repris. Les anciennes neuf créations de la pile cash V14 ne sont pas ce paquet physique.

Dépendances observées par RPC Base Sepolia le 11 novembre : mWETH `0x4DeEBc5f537F3b8ba0E3393807B4D699D72bDd02` (18 décimales), mUSDC `0x6eAe407f5640B006faC9965182e238582A3B412E` (6 décimales), OracleRouter `0xB416406F200B2Ef3D7a86A5D5877Ed41D9B1A581`, Timelock ci-dessus ; chacun possédait du bytecode. `getPriceSafe(mWETH,mUSDC)` a retourné `205408645749` en 1e8 (2 054,08645749 USD), timestamp `2026-11-11T10:02:58Z`, `valid=true`. Il s'agit d'une lecture ponctuelle ; refaire le contrôle de fraîcheur au préflight de la création et de la première transaction.

Gas mesuré sur les receipts Anvil du banc V21, une transaction par création : Registry 3 728 978 ; moteur physique 2 370 802 ; matcher 2 547 420 ; total créations 8 647 200. La configuration sélectionnée du banc (autorisation des actifs, série, caps, frais, exécuteur, gel, liaison, ouverture locale) ajoute 599 557 gas, soit 9 246 757 gas pour ce sous-ensemble hors gouvernance, guardian, désactivation de série et surcoûts réseau. Aucun des trois déploiements individuels n'approche la limite Base Sepolia de 16 777 216 gas par transaction. Ce sont des mesures locales, pas des estimations finales du Safe/Timelock ; recalculer par transaction au préflight, puis conserver une marge de gas. Les adresses de ces receipts locaux ne sont pas des adresses prédites sur Base Sepolia.

Configuration gouvernée, **à préparer et autoriser séparément** : autoriser mUSDC et mWETH dans le nouveau Registry ; créer la série Call avec la date et le strike requalifiés, puis la désactiver avant toute liaison du matcher ; déployer le moteur et le matcher ; `configureExposureCaps(1,1)` ; `configureFees(address(0),0,0)` ; définir guardian et exécuteur applicatif après vérification de leurs identités ; figer les pointeurs du matcher, lier le moteur, vérifier les états et seulement ensuite envisager une activation distincte. `createSeries` crée une série ACTIVE immédiatement ; tant que le moteur n'existe pas ou reste pausé, cela ne rend pas le trading possible. La fenêtre entre création et désactivation doit rester sans moteur actif. Aucun changement du Registry ou du Vault historique.

## Préflight, postflight et arrêt

Avant toute transaction future : contrôler chainId, bytecodes, permissions Timelock/Safe, nonces, gas par transaction, adresses de tokens et décimales, prix ETH et fraîcheur de `getPriceSafe`, strike/échéance, bilan de l'escrow, soldes des anciens contrats, flags économiques fermés et état de la sauvegarde R2. Chaque opération de déploiement, chaque configuration, l'activation économique et le premier trade exigent des autorisations distinctes. Aucune transaction n'est autorisée par ce document.

Après chaque création, comparer le receipt, le code, les constructeurs et les pointeurs. Après configuration, contrôler `maxOpenContracts=1`, `maxWalletOpenContracts=1`, frais nuls, engine pausé, matcher exact, executor unique approuvé, ancien Vault inchangé et aucune série historique migrée. Si un contrôle échoue, ne pas ouvrir : laisser le moteur pausé et ne pas lier ou autoriser un exécuteur. Une série active doit être désactivée par la gouvernance avant tout autre travail.

La migration PostgreSQL 0074 est à faire séparément avec sauvegarde et rôle dédié, jamais par le rôle runtime. La candidate et l'image de repli doivent toutes deux accepter exactement 74 migrations et conserver les gardes économiques. Aucun rollback par restauration automatique ni retour à l'image 72. Netcup et Vercel restent inchangés jusqu'à autorisation de release distincte.

Images **locales seulement** testées le 11 novembre sur restauration R2 : candidate backend V20 `084ff67` (`sha256:d6b7e2422c25a5ec656d7887f5a5e02a5d3595bc4355b59a7b56fa1f1ff3397c`), repli sur la branche locale `options-v21-schema74-rollback` commit `9d28cb2` (`sha256:b689ee1147792235562a043b8c78cfee27351fd7728c99f3bbebe9bb876381bb`). Ces identifiants Docker locaux ne sont pas des digests GHCR publiés. La commande `GNUPGHOME=/home/corio/.local/share/deopt-backup-gpg bash scripts/options-v21-image-rollback-drill.sh /tmp/deopt-v20-latest-20261111T084250Z.dump.gpg 84be4c7821996a90d4bdc334527524669a2552ca2b2145afe2e9e5d298c4dd31` migre 72→74 sur PostgreSQL 16 jetable, puis vérifie candidate→repli→candidate, challenge/signature/session persistante, refus anonyme et écritures économiques, sans restauration destructive. Il contrôle séparément les empreintes des 92 tables non liées à l'authentification et des anciennes lignes d'authentification. Le futur déploiement doit produire et vérifier de nouveaux digests immuables avant toute opération hébergée.

## Limites économiques explicites

La solvabilité physique est assurée uniquement pour les mWETH effectivement transférés et verrouillés à chaque fill. Elle ne garantit ni liquidité mUSDC de l'acheteur à l'exercice, ni disponibilité d'un prix oracle pour ouvrir de nouveaux trades. Si aucun exercice n'est effectué, le droit de l'acheteur s'éteint au bout de 48 heures et le vendeur récupère le mWETH. Le strike et la date candidats doivent être confirmés juste avant la création. La bêta publique et le mainnet ne sont pas approuvés.
