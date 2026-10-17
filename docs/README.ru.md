# wardrobe

[简体中文](README.zh-CN.md) · [繁體中文](README.zh-TW.md) · [English](../README.md) · [Français](README.fr.md) · [Deutsch](README.de.md) · [日本語](README.ja.md) · **Русский**

<img src="clipline-icon.png" alt="Значок wardrobe" width="80">

Полка для macOS со скриншотами и скопированными текстами, ссылками, изображениями и файлами. Копируйте содержимое целиком или перетаскивайте карточку в другое приложение.

Разработчик — **[@a2289866844](https://github.com/a2289866844)**. Прежнее название — Clipline.

## Возможности

В **предварительной версии 1.2** появились поиск по истории, поиск китайского текста и текста на скриншотах с помощью OCR, закрепление карточек и редактирование текста. Просматривайте до 120 последних элементов по шесть карточек за раз; старые элементы в архиве тоже доступны для поиска.

**Control + Option + T** показывает и скрывает полку. **Command + Shift + V** открывает поиск в версии 1.2. Наведите указатель на область рядом с вырезом экрана или на середину верхнего края, чтобы показать карточки.

## Скачать

| Версия | Требования | Загрузка |
| --- | --- | --- |
| 1.1.6 стабильная — под прежним названием Clipline | macOS 14+ | [DMG / ZIP](https://github.com/a2289866844/Your-mums-wardrobe/releases/tag/clipline-v1.1.6) |
| 1.2 предварительная для разработчиков — история, поиск и OCR | macOS 15+, Swift 6 | [Сборка из исходников](https://github.com/a2289866844/Your-mums-wardrobe/tree/codex/clipline-public-1.2); установщик пока не опубликован |

Приложение в стабильном установщике по-прежнему называется `Clipline.app` и выпущено до добавления архива. Оно использует подпись ad hoc и не прошло нотариальную проверку Apple. [Установка стабильной версии](https://github.com/a2289866844/Your-mums-wardrobe/blob/976a4ad/README.md) · [Ранняя демонстрация скриншотов и перетаскивания в 1.1](https://github.com/a2289866844/Your-mums-wardrobe/releases/download/clipline-v1.1.3/Clipline-1.1.3-demo.mp4)

<details>
<summary>Собрать предварительную версию 1.2</summary>

```sh
git clone --branch codex/clipline-public-1.2 https://github.com/a2289866844/Your-mums-wardrobe.git
cd Your-mums-wardrobe
swift test
scripts/build-app.sh
open build/wardrobe.app
```

</details>

История хранится на Mac в **незашифрованной базе SQLite**. Перед копированием конфиденциальных данных приостановите **Hang copied items**. Существующие зашифрованные архивы Clipd требуют отдельного преобразования офлайн с исходным ключом и резервной копией. [Хранение и совместимость](https://github.com/a2289866844/Your-mums-wardrobe/blob/codex/clipline-public-1.2/docs/reviews/clipline-clipd-integration.md)

Основано на **[Tendedero](https://github.com/alejandrobujan/tendedero) от Alejandro Buján**. Независимое модифицированное приложение. [Участники и благодарности](https://github.com/a2289866844/Your-mums-wardrobe/blob/codex/clipline-public-1.2/AUTHORS.md) · [Лицензия](https://github.com/a2289866844/Your-mums-wardrobe/blob/codex/clipline-public-1.2/LICENSE) · [Сообщить о проблеме](https://github.com/a2289866844/Your-mums-wardrobe/issues)
