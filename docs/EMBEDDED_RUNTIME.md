# Вбудований рушій Portico

Portico 0.2 збирається з Wine Stable 11.0_1 і приватним GStreamer 1.28.1. Це локальна збірка для розробки. Вона не є випуском із підписом для розповсюдження або схваленням Mac App Store.

## Склад комплекту

```text
Portico.app/Contents/
  MacOS/Portico
  Frameworks/WineRuntime/{bin,lib,share}
  Frameworks/GStreamer.framework/
  Resources/WineRuntime/{lib/wine/*-windows,share}
  Resources/RuntimeManifest.json
  Resources/RuntimeLicenses/
```

Wine містить Gecko 2.47.4 і Mono 10.4.1 з початкової збірки. Нативні компоненти Wine — x86_64; на Apple Silicon потрібна системна Rosetta 2. Portico не розповсюджує Rosetta. Префікси, ігри, журнали й кеші записуються в користувацькі каталоги, а не всередину застосунку.

Windows PE-файли та дані фізично розміщені в `Resources`, а початкові шляхи Wine збережено внутрішніми відносними посиланнями. Це дає macOS змогу підписувати нативні компоненти окремо від Windows-коду. Необов'язковий Python-плагін GStreamer вилучено: офіційний пакет із ним потребував зовнішнього Python із Xcode. Рушій із медіабібліотеками займає близько 1,3 ГіБ до стиснення.

Вбудовані середовища посилаються на ідентифікатор випуску, а шлях обчислюється з поточного розташування `.app`. Перенесення застосунку не змінює прив'язку середовища. Невідповідність версії не спричиняє непомітного перемикання на інший Wine. Явно вибрані зовнішні рушії залишаються зовнішніми.

## Підготовка та збірка

Потрібні Xcode Command Line Tools, Swift і Python 3. Скрипти не встановлюють системні пакети й не використовують `sudo`.

1. Wine із закріпленого `RuntimeCatalog` потрібно завантажити штатним інсталятором Portico з перевіркою SHA-256. Для описаної локальної розробки його збережено в `~/Library/Application Support/Portico/Runtimes/wine-stable-11.0_1/`.
2. Завантажте офіційний `gstreamer-1.0-1.28.1-universal.pkg` за URL із `RuntimeCatalog`. Пакет використовується лише для розпакування. Потрібний SHA-256: `02803f73435daabe8fb12b79c38c6775d0efb83af001474558ba25c4f874d305`.
3. Підготуйте копію runtime:

```sh
python3 scripts/prepare-embedded-runtime.py \
  --wine-app "$HOME/Library/Application Support/Portico/Runtimes/wine-stable-11.0_1/Wine Stable.app" \
  --gstreamer-pkg work/runtime-downloads/gstreamer-1.0-1.28.1-universal.pkg \
  --output work/embedded-runtime
scripts/build-app.sh
```

Результат — `dist/Portico.app`. Без підготовленого рушія стандартна збірка зупиняється, щоб випадково не випустити порожню оболонку. Для окремої slim-збірки розробника є явний прапорець `scripts/build-app.sh --without-runtime`.

Скрипт підготовки зберігає початкову інсталяцію Wine, розпаковує GStreamer через `pkgutil`, переналаштовує посилання Mach-O на сусідні файли всередині комплекту й перевіряє залежності. Скрипт збірки формує новий bundle і підписує нативні компоненти зсередини назовні ad-hoc підписом для локальної розробки. Він не змінює налаштування Gatekeeper і не видаляє quarantine. Перевірка цілісності підпису не є дозволом Gatekeeper.

## Перед публічним випуском

Потрібні точні ліцензії та відповідні вихідні коди всіх компонентів, що розповсюджуються, відтворюване походження сторонніх бібліотек, підписи вибраного каналу розповсюдження й окрема перевірка Sandbox. Комплект `RuntimeLicenses` поки не підтверджує виконання всіх ліцензійних зобов'язань. Докладний аудит і першоджерела — в [EMBEDDED_RUNTIME_NOTES.md](EMBEDDED_RUNTIME_NOTES.md).

Наявність Wine не гарантує роботу DirectX 12. D3DMetal, DXVK і перевірений DX12 → Metal backend до цього комплекту не входять. Gothic 1 Remake і Divinity: Original Sin 2 потребують окремих ігрових випробувань. Результати запуску фіксуються в [VALIDATION.md](VALIDATION.md).
