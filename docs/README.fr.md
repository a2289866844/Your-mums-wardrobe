# wardrobe

[简体中文](README.zh-CN.md) · [繁體中文](README.zh-TW.md) · [English](../README.md) · **Français** · [Deutsch](README.de.md) · [日本語](README.ja.md) · [Русский](README.ru.md)

<img src="clipline-icon.png" alt="Icône de wardrobe" width="80">

Une étagère macOS pour les captures d’écran, le texte, les liens, les images et les fichiers copiés. Copiez le contenu intégral ou glissez une carte dans une autre app.

Développé par **[@a2289866844](https://github.com/a2289866844)**. Anciennement Clipline.

## Fonctionnalités

La **préversion 1.2** ajoute un historique consultable, la recherche en chinois et par OCR des captures, des cartes épinglées et la modification du texte. Parcourez six cartes à la fois, parmi 120 éléments récents maximum ; les archives plus anciennes restent accessibles par recherche.

**Control + Option + T** affiche ou masque l’étagère. **Command + Shift + V** ouvre la recherche en 1.2. Survolez l’encoche ou le centre du bord supérieur pour afficher les cartes.

## Télécharger

| Version | Prérequis | Téléchargement |
| --- | --- | --- |
| 1.1.6 stable — ancien nom Clipline | macOS 14+ | [DMG / ZIP](https://github.com/a2289866844/Your-mums-wardrobe/releases/tag/clipline-v1.1.6) |
| Préversion développeur 1.2 — historique, recherche et OCR | macOS 15+, Swift 6 | [Compiler les sources](https://github.com/a2289866844/Your-mums-wardrobe/tree/codex/clipline-public-1.2) ; aucun installateur publié pour l’instant |

L’installateur stable fournit encore `Clipline.app` et précède les fonctions d’archivage. L’app utilise une signature ad hoc et n’est pas notariée par Apple. [Guide d’installation stable](https://github.com/a2289866844/Your-mums-wardrobe/blob/976a4ad/README.md) · [Ancienne démo 1.1 : captures et glisser-déposer](https://github.com/a2289866844/Your-mums-wardrobe/releases/download/clipline-v1.1.3/Clipline-1.1.3-demo.mp4)

<details>
<summary>Compiler la préversion 1.2</summary>

```sh
git clone --branch codex/clipline-public-1.2 https://github.com/a2289866844/Your-mums-wardrobe.git
cd Your-mums-wardrobe
swift test
scripts/build-app.sh
open build/wardrobe.app
```

</details>

L’historique reste sur le Mac dans une **base SQLite non chiffrée**. Mettez **Hang copied items** en pause avant de copier du contenu sensible. Les archives Clipd chiffrées existantes nécessitent une conversion hors ligne distincte, avec la clé d’origine et une sauvegarde. [Stockage et compatibilité](https://github.com/a2289866844/Your-mums-wardrobe/blob/codex/clipline-public-1.2/docs/reviews/clipline-clipd-integration.md)

Basé sur **[Tendedero](https://github.com/alejandrobujan/tendedero) d’Alejandro Buján**. Application modifiée indépendante. [Contributions et crédits](https://github.com/a2289866844/Your-mums-wardrobe/blob/codex/clipline-public-1.2/AUTHORS.md) · [Licence](https://github.com/a2289866844/Your-mums-wardrobe/blob/codex/clipline-public-1.2/LICENSE) · [Signaler un problème](https://github.com/a2289866844/Your-mums-wardrobe/issues)
