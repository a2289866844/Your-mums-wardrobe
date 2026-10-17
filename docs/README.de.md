# wardrobe

[简体中文](README.zh-CN.md) · [繁體中文](README.zh-TW.md) · [English](../README.md) · [Français](README.fr.md) · **Deutsch** · [日本語](README.ja.md) · [Русский](README.ru.md)

<img src="clipline-icon.png" alt="wardrobe-Symbol" width="80">

Eine macOS-Ablage für Screenshots sowie kopierte Texte, Links, Bilder und Dateien. Kopiere den vollständigen Inhalt oder ziehe eine Karte in eine andere App.

Entwickelt von **[@a2289866844](https://github.com/a2289866844)**. Hieß zuvor Clipline.

## Funktionen

Die **1.2-Vorschau** ergänzt einen durchsuchbaren Verlauf, Suche in chinesischen Texten und OCR-Suche in Screenshots, angeheftete Karten und Textbearbeitung. Blättere durch jeweils sechs Karten mit bis zu 120 aktuellen Einträgen; ältere archivierte Einträge bleiben durchsuchbar.

**Control + Option + T** blendet die Ablage ein oder aus. **Command + Shift + V** öffnet die Suche in 1.2. Bewege den Mauszeiger zur Notch oder zur Mitte des oberen Bildschirmrands, um Karten einzublenden.

## Download

| Version | Voraussetzungen | Download |
| --- | --- | --- |
| 1.1.6 stabil — bisheriger Name Clipline | macOS 14+ | [DMG / ZIP](https://github.com/a2289866844/Your-mums-wardrobe/releases/tag/clipline-v1.1.6) |
| 1.2-Entwicklervorschau — Verlauf, Suche und OCR | macOS 15+, Swift 6 | [Aus dem Quellcode bauen](https://github.com/a2289866844/Your-mums-wardrobe/tree/codex/clipline-public-1.2); noch kein veröffentlichtes Installationspaket |

Das stabile Installationspaket enthält weiterhin `Clipline.app` und stammt aus der Zeit vor den Archivfunktionen. Die App verwendet eine Ad-hoc-Signatur und ist nicht von Apple notarisiert. [Installationsanleitung für die stabile Version](https://github.com/a2289866844/Your-mums-wardrobe/blob/976a4ad/README.md) · [Frühere 1.1-Demo: Screenshots und Ziehen](https://github.com/a2289866844/Your-mums-wardrobe/releases/download/clipline-v1.1.3/Clipline-1.1.3-demo.mp4)

<details>
<summary>Die 1.2-Vorschau bauen</summary>

```sh
git clone --branch codex/clipline-public-1.2 https://github.com/a2289866844/Your-mums-wardrobe.git
cd Your-mums-wardrobe
swift test
scripts/build-app.sh
open build/wardrobe.app
```

</details>

Der Verlauf bleibt auf dem Mac in einer **unverschlüsselten SQLite-Datenbank**. Pausiere **Hang copied items**, bevor du vertrauliche Inhalte kopierst. Vorhandene verschlüsselte Clipd-Archive erfordern eine separate Offline-Konvertierung mit dem ursprünglichen Schlüssel und einer Sicherungskopie. [Details zu Speicherung und Kompatibilität](https://github.com/a2289866844/Your-mums-wardrobe/blob/codex/clipline-public-1.2/docs/reviews/clipline-clipd-integration.md)

Basiert auf **[Tendedero](https://github.com/alejandrobujan/tendedero) von Alejandro Buján**. Eigenständige, modifizierte Anwendung. [Beiträge und Danksagungen](https://github.com/a2289866844/Your-mums-wardrobe/blob/codex/clipline-public-1.2/AUTHORS.md) · [Lizenz](https://github.com/a2289866844/Your-mums-wardrobe/blob/codex/clipline-public-1.2/LICENSE) · [Problem melden](https://github.com/a2289866844/Your-mums-wardrobe/issues)
